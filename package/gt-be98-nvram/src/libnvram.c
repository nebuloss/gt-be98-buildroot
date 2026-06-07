/*
 * gt-be98 open libnvram - userspace NETLINK_WLCSM (proto 31) client for the
 * OPEN in-kernel store bcm_knvram.ko.
 *
 * This is a clean-room reimplementation of the (closed, prebuilt) vendor
 * libnvram.so, written against the OPEN GPL kernel source that defines the
 * wire protocol:
 *   - bcm_knvram/impl1/include/wlcsm_linux.h   (framing + pair packing)
 *   - bcm_knvram/impl1/src/wlcsm_netlink.c     (request dispatch)
 *   - bcm_knvram/impl1/src/wlcsm_nvram.c       (set/get/getall semantics)
 *
 * The verdict for this path is REIMPLEMENT (RE map: nvram CLI + libnvram
 * netlink client is closed; the protocol is fully open). The legacy open
 * merlin nvram_linux.c is the WRONG backend (/dev/nvram ioctl / file) and is
 * NOT what the device runs - hence this from-protocol client rather than a
 * recompile.
 *
 * STATUS: builds clean to ARM32; protocol matches the open kernel source.
 * NOT yet validated against a live bcm_knvram.ko (offline, no device) - bench
 * test required before trusting on a unit.
 *
 * NO-GO policy (RE map sec.5): callers must never set/unset/commit MAC-class
 * vars (et0macaddr, *_hwaddr, label_mac) - those are owned by envrams/kernel.
 * This library does not enforce it; the policy lives in the caller.
 *
 * SPDX-License-Identifier: GPL-2.0
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/uio.h>
#include <linux/netlink.h>

#include "nvram_wlcsm.h"
#include "nvram.h"

/* Userspace persistence file (RE map sec.3): commit rewrites the whole file
 * atomically. bcm_knvram COMMIT is a kernel no-op; persistence is here. */
#ifndef NVRAM_FILE
#define NVRAM_FILE      "/data/.kernel_nvram.setting"
#endif
#define NVRAM_FILE_NEW  NVRAM_FILE "_new"
#define NVRAM_FILE_OLD  NVRAM_FILE "_old"

/* getall drain bounds. The kernel pages the tree in fixed chunks and signals
 * end only via a GETALL_DONE message type (NOT via a short page), so the drain
 * loops on index until DONE. These guards keep a misbehaving/streaming kernel
 * from spinning forever or overflowing the destination buffer. */
#define NVRAM_GETALL_MAX_PAGES  65536          /* runaway-loop guard */
#define NVRAM_COMMIT_INIT_CAP   (256 * 1024)   /* initial commit dump buffer */
#define NVRAM_COMMIT_MAX_CAP    (8  * 1024 * 1024) /* refuse to grow past this */

static int g_sock = -1;
static int g_commit_reqd = 0;
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static __thread char g_get_buf[WLCSM_NAMEVALUEPAIR_MAX];

/* ---- transport ---------------------------------------------------------- */

static int nl_open(void)
{
	struct sockaddr_nl sa;
	int s;

	s = socket(AF_NETLINK, SOCK_RAW, NETLINK_WLCSM);
	if (s < 0)
		return -1;
	memset(&sa, 0, sizeof(sa));
	sa.nl_family = AF_NETLINK;
	sa.nl_pid    = getpid();
	if (bind(s, (struct sockaddr *)&sa, sizeof(sa)) < 0) {
		close(s);
		return -1;
	}
	return s;
}

static int nl_ensure(void)
{
	if (g_sock < 0)
		g_sock = nl_open();
	return g_sock;
}

/* Send one request: nlmsghdr + t_WLCSM_MSG_HDR + payload(len). */
static int nl_send(unsigned short type, const void *payload, int len)
{
	char buf[NLMSG_SPACE(sizeof(t_WLCSM_MSG_HDR) + WLCSM_NAMEVALUEPAIR_MAX)];
	struct nlmsghdr *nlh = (struct nlmsghdr *)buf;
	struct sockaddr_nl dst;
	t_WLCSM_MSG_HDR *mh;
	int hlen = sizeof(t_WLCSM_MSG_HDR) + (len > 0 ? len : 0);

	if (len < 0 || (size_t)hlen > sizeof(t_WLCSM_MSG_HDR) + WLCSM_NAMEVALUEPAIR_MAX)
		return -1;

	memset(buf, 0, NLMSG_SPACE(hlen));
	nlh->nlmsg_len   = NLMSG_LENGTH(hlen);
	nlh->nlmsg_pid   = getpid();
	nlh->nlmsg_flags = 0;
	nlh->nlmsg_type  = 0;

	mh = (t_WLCSM_MSG_HDR *)NLMSG_DATA(nlh);
	mh->type = type;
	mh->len  = (unsigned short)(len > 0 ? len : 0);
	mh->pid  = getpid();
	if (len > 0)
		memcpy((char *)mh + sizeof(*mh), payload, len);

	memset(&dst, 0, sizeof(dst));
	dst.nl_family = AF_NETLINK;
	dst.nl_pid    = 0;   /* kernel */

	if (sendto(g_sock, nlh, nlh->nlmsg_len, 0,
		   (struct sockaddr *)&dst, sizeof(dst)) < 0)
		return -1;
	return 0;
}

/* Receive one reply; copies up to *outlen payload bytes into out, sets *rtype.
 * Returns the number of payload bytes placed into out (>=0), or -1 on error.
 *
 * Hardened vs the original: (1) the receive buffer is sized well above any
 * single kernel page (the kernel header itself warns MAX_NLRCV_BUF_SIZE must
 * exceed NL_PACKET_SIZE) and recvmsg's MSG_TRUNC flag is checked so a datagram
 * is never silently chopped; (2) the claimed payload length (t_WLCSM_MSG_HDR.len)
 * is clamped to the bytes actually delivered so we can never over-read stale
 * stack into the caller's stream; (3) the return value is the count actually
 * copied, so the drain's running offset always matches the bytes assembled. */
static int nl_recv(unsigned short *rtype, void *out, int outlen)
{
	char rbuf[2 * MAX_NLRCV_BUF_SIZE + NLMSG_HDRLEN];
	struct iovec iov = { rbuf, sizeof(rbuf) };
	struct sockaddr_nl sa;
	struct msghdr msg;
	struct nlmsghdr *nlh = (struct nlmsghdr *)rbuf;
	t_WLCSM_MSG_HDR *mh;
	int n, plen, avail;

	memset(&msg, 0, sizeof(msg));
	msg.msg_name    = &sa;
	msg.msg_namelen = sizeof(sa);
	msg.msg_iov     = &iov;
	msg.msg_iovlen  = 1;

	do {
		n = recvmsg(g_sock, &msg, 0);
	} while (n < 0 && errno == EINTR);  /* a transient signal must not truncate the stream */
	if (n <= 0)
		return -1;
	if (msg.msg_flags & MSG_TRUNC)      /* page larger than rbuf: bail, never assemble garbage */
		return -1;
	if (!NLMSG_OK(nlh, (unsigned)n))
		return -1;
	mh = (t_WLCSM_MSG_HDR *)NLMSG_DATA(nlh);
	if (rtype)
		*rtype = mh->type;
	plen  = (int)mh->len;               /* unsigned short field, always >= 0 */
	avail = n - NLMSG_HDRLEN - (int)sizeof(*mh);
	if (avail < 0)
		avail = 0;
	if (plen > avail)                   /* header claims more than was delivered */
		plen = avail;
	if (out && outlen > 0) {
		int cp = plen < outlen ? plen : outlen;
		memcpy(out, (char *)mh + sizeof(*mh), cp);
		return cp;
	}
	return plen;
}

/* ---- public API --------------------------------------------------------- */

int nvram_init(void *unused)
{
	(void)unused;
	pthread_mutex_lock(&g_lock);
	(void)nl_ensure();
	pthread_mutex_unlock(&g_lock);
	return g_sock < 0 ? -1 : 0;
}

char *nvram_get(const char *name)
{
	unsigned short rt;
	int plen;
	const char *val;
	int vlen;

	if (!name || !*name)
		return NULL;
	pthread_mutex_lock(&g_lock);
	if (nl_ensure() < 0) { pthread_mutex_unlock(&g_lock); return NULL; }

	/* GET payload = plain name string (kernel wlcsm_nvram_get uses it raw). */
	if (nl_send(WLCSM_MSG_NVRAM_GET, name, (int)strlen(name) + 1) < 0) {
		pthread_mutex_unlock(&g_lock);
		return NULL;
	}
	plen = nl_recv(&rt, g_get_buf, sizeof(g_get_buf));
	if (plen <= 0 || rt != WLCSM_MSG_NVRAM_GET) {
		pthread_mutex_unlock(&g_lock);
		return NULL;          /* unset => kernel replies len 0 */
	}
	/* reply is a full packed pair; extract the value substring */
	val = wlcsm_pair_value(g_get_buf, &vlen);
	pthread_mutex_unlock(&g_lock);
	return (char *)val;       /* into thread-local g_get_buf */
}

int nvram_set(const char *name, const char *value)
{
	char pkt[WLCSM_NAMEVALUEPAIR_MAX];
	unsigned short rt;
	int len;

	if (!name || !*name)
		return -1;
	len = wlcsm_pair_total_len(name, value ? value : "");
	if (len >= WLCSM_NAMEVALUEPAIR_MAX)
		return -1;
	pthread_mutex_lock(&g_lock);
	if (nl_ensure() < 0) { pthread_mutex_unlock(&g_lock); return -1; }
	len = wlcsm_pair_pack(pkt, name, value ? value : "");
	if (nl_send(WLCSM_MSG_NVRAM_SET, pkt, len) < 0) {
		pthread_mutex_unlock(&g_lock);
		return -1;
	}
	(void)nl_recv(&rt, NULL, 0);   /* kernel echoes the request */
	g_commit_reqd = 1;
	pthread_mutex_unlock(&g_lock);
	return 0;
}

int nvram_unset(const char *name)
{
	char pkt[WLCSM_NAMEVALUEPAIR_MAX];
	unsigned short rt;
	int len;

	if (!name || !*name)
		return -1;
	pthread_mutex_lock(&g_lock);
	if (nl_ensure() < 0) { pthread_mutex_unlock(&g_lock); return -1; }
	/* UNSET payload = packed pair (kernel uses VALUEPAIR_NAME(buf) = buf+4). */
	len = wlcsm_pair_pack(pkt, name, NULL);
	if (nl_send(WLCSM_MSG_NVRAM_UNSET, pkt, len) < 0) {
		pthread_mutex_unlock(&g_lock);
		return -1;
	}
	(void)nl_recv(&rt, NULL, 0);
	g_commit_reqd = 1;
	pthread_mutex_unlock(&g_lock);
	return 0;
}

/*
 * nl_getall_drain: assemble the kernel's whole NUL-separated tree into buf.
 *
 * Protocol (bcm_knvram/impl1 wlcsm_netlink.c:484, wlcsm_nvram.c:511): the kernel
 * pages the tree as a flat byte stream. req[1] is the PAGE INDEX; the kernel
 * reads at byte offset index*pagesize and reconstructs the tail of any entry
 * straddling the page boundary, so raw concatenation of page payloads is
 * byte-exact. The ONLY end condition is a reply of type GETALL_DONE (which may
 * be a short or even empty page) - a full-size page is always "more to come".
 * req[0] is a size hint the kernel ignores.
 *
 * This is the single source of truth for both nvram_getall() and the commit
 * dump, so the two paths can never diverge. The caller must hold g_lock.
 *
 * Returns the number of stream bytes written (NOT counting the trailing
 * double-NUL it appends), or -1 on a transport/protocol error. *complete is set
 * to 1 iff the kernel's GETALL_DONE marker was seen (i.e. the full stream fit in
 * buf); 0 means buf filled first and the stream is truncated.
 */
static int nl_getall_drain(char *buf, int cap, int *complete)
{
	int index = 0, off = 0;

	if (complete)
		*complete = 0;
	if (!buf || cap <= 0)
		return -1;

	for (;;) {
		int req[2];
		unsigned short rt = 0;
		int plen, room = cap - off;

		/* Reserve 2 bytes so we can always double-NUL terminate. */
		if (room <= 2)
			return off;                 /* buffer full, not complete */

		req[0] = room;                      /* size hint (kernel ignores) */
		req[1] = index;                     /* page index */
		if (nl_send(WLCSM_MSG_NVRAM_GETALL, req, sizeof(req)) < 0)
			return -1;
		plen = nl_recv(&rt, buf + off, room - 2);
		if (plen < 0)
			return -1;                  /* never assemble a partial page */
		off += plen;                        /* nl_recv returns bytes placed */

		if (rt == WLCSM_MSG_NVRAM_GETALL_DONE) {
			if (complete)
				*complete = 1;          /* kernel signalled end of stream */
			break;
		}
		if (rt != WLCSM_MSG_NVRAM_GETALL)
			return -1;                  /* ERR/BUSY/unexpected: do not trust */
		if (++index > NVRAM_GETALL_MAX_PAGES)
			return -1;                  /* runaway guard */
	}

	/* double-NUL terminate the stream (room for 2 was reserved above) */
	buf[off] = '\0';
	buf[off + 1] = '\0';
	return off;
}

/*
 * nvram_getall: fill buf with the whole tree as "name=value\0name=value\0\0".
 * Drains every page until the kernel's GETALL_DONE marker (see nl_getall_drain).
 * With a fixed caller buffer, a stream larger than count is truncated to count
 * (bounded); the CLI passes 256 KiB which exceeds the live ~182 KiB stream.
 */
int nvram_getall(char *buf, int count)
{
	int off, complete = 0;

	if (!buf || count <= 0)
		return -1;
	pthread_mutex_lock(&g_lock);
	if (nl_ensure() < 0) { pthread_mutex_unlock(&g_lock); return -1; }
	off = nl_getall_drain(buf, count, &complete);
	pthread_mutex_unlock(&g_lock);
	return off;
}

/*
 * nvram_commit: persist the live kernel tree to NVRAM_FILE (whole-file atomic
 * rewrite). The kernel COMMIT message is a no-op notification; persistence is
 * userspace. Batches: only writes when something changed (commit_reqd).
 * One commit == one full NAND rewrite - never call in a poll loop.
 */
int nvram_commit(void)
{
	char *all;
	int n, fd, p;
	unsigned short rt;

	pthread_mutex_lock(&g_lock);
	if (!g_commit_reqd) { pthread_mutex_unlock(&g_lock); return 0; }
	if (nl_ensure() < 0) { pthread_mutex_unlock(&g_lock); return -1; }

	/* notify the kernel/listeners (matches vendor behaviour) */
	if (nl_send(WLCSM_MSG_NVRAM_COMMIT, NULL, 0) == 0)
		(void)nl_recv(&rt, NULL, 0);

	/*
	 * Capture the COMPLETE current key set via the SAME drain as nvram_getall
	 * (re-entering the public API would deadlock on g_lock, so call the
	 * lock-free helper directly). The commit path must NOT censor or drop
	 * anything - it persists the whole tree byte-for-byte - so it relies on
	 * nl_getall_drain's GETALL_DONE termination and grows its buffer rather
	 * than ever writing a truncated stream (which would silently corrupt the
	 * config file). If the stream cannot be captured in full, the commit is
	 * ABORTED and the existing file is left untouched.
	 */
	{
		int cap = NVRAM_COMMIT_INIT_CAP, complete = 0;
		all = NULL; n = -1;
		for (;;) {
			char *nb = realloc(all, cap);
			if (!nb) { free(all); all = NULL; break; }
			all = nb;
			n = nl_getall_drain(all, cap, &complete);
			if (n < 0) break;            /* transport/protocol error */
			if (complete) break;         /* full stream captured */
			if (cap >= NVRAM_COMMIT_MAX_CAP) { n = -1; break; }
			cap *= 2;                    /* grow and re-drain from page 0 */
		}
		if (!all || n < 0 || !complete) {
			free(all);
			pthread_mutex_unlock(&g_lock);
			return -1;                   /* refuse to persist a partial tree */
		}
	}

	fd = open(NVRAM_FILE_NEW, O_WRONLY | O_CREAT | O_TRUNC, 0644);
	if (fd < 0) { free(all); pthread_mutex_unlock(&g_lock); return -1; }
	/* Write "name=value\n" lines from the NUL-separated stream. */
	for (p = 0; p < n; ) {
		int l = (int)strlen(all + p);
		if (l == 0) { p++; continue; }
		if (write(fd, all + p, l) != l) { close(fd); free(all);
			pthread_mutex_unlock(&g_lock); return -1; }
		if (write(fd, "\n", 1) != 1) { /* ignore */ }
		p += l + 1;
	}
	fsync(fd);
	close(fd);
	free(all);

	(void)rename(NVRAM_FILE, NVRAM_FILE_OLD);
	if (rename(NVRAM_FILE_NEW, NVRAM_FILE) < 0) {
		pthread_mutex_unlock(&g_lock);
		return -1;
	}
	g_commit_reqd = 0;
	pthread_mutex_unlock(&g_lock);
	return 0;
}

/* RAM-only variants (no flash write) - per vendor symbol table. */
int nvram_kset(const char *name, const char *value) { return nvram_set(name, value); }
int nvram_kcommit(void) { return 0; }
int nvram_commit_reqd(void) { return g_commit_reqd; }

/* wlcsm_* aliases so closed consumers / libshared link unchanged. */
char *wlcsm_nvram_get(const char *name)              { return nvram_get(name); }
int   wlcsm_nvram_set(const char *n, const char *v)  { return nvram_set(n, v); }
int   wlcsm_nvram_unset(const char *name)            { return nvram_unset(name); }
int   wlcsm_nvram_getall(char *buf, int count)       { return nvram_getall(buf, count); }
int   wlcsm_nvram_commit(void)                       { return nvram_commit(); }
