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
 * Returns payload length (>=0) or -1 on error. */
static int nl_recv(unsigned short *rtype, void *out, int outlen)
{
	char rbuf[MAX_NLRCV_BUF_SIZE + NLMSG_HDRLEN];
	struct nlmsghdr *nlh = (struct nlmsghdr *)rbuf;
	t_WLCSM_MSG_HDR *mh;
	int n, plen;

	n = recv(g_sock, rbuf, sizeof(rbuf), 0);
	if (n <= 0)
		return -1;
	if (!NLMSG_OK(nlh, (unsigned)n))
		return -1;
	mh = (t_WLCSM_MSG_HDR *)NLMSG_DATA(nlh);
	if (rtype)
		*rtype = mh->type;
	plen = mh->len;
	if (plen < 0)
		return -1;
	if (out && outlen > 0) {
		int cp = plen < outlen ? plen : outlen;
		memcpy(out, (char *)mh + sizeof(*mh), cp);
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
 * nvram_getall: fill buf with the whole tree as "name=value\0name=value\0\0".
 * Pages via index 0,1,.. until the kernel replies GETALL_DONE (short page).
 * Concatenating page payloads reconstructs the kernel's NUL-separated stream
 * (the kernel emits the tail of any entry straddling a page boundary).
 */
int nvram_getall(char *buf, int count)
{
	int index = 0, off = 0;

	if (!buf || count <= 0)
		return -1;
	pthread_mutex_lock(&g_lock);
	if (nl_ensure() < 0) { pthread_mutex_unlock(&g_lock); return -1; }

	for (;;) {
		int req[2];
		unsigned short rt = 0;
		int plen;

		req[0] = count;     /* size hint */
		req[1] = index;     /* page */
		if (nl_send(WLCSM_MSG_NVRAM_GETALL, req, sizeof(req)) < 0)
			break;
		plen = nl_recv(&rt, buf + off, count - off);
		if (plen < 0)
			break;
		off += (plen < count - off) ? plen : (count - off);
		if (rt == WLCSM_MSG_NVRAM_GETALL_DONE || off >= count)
			break;
		index++;
	}
	if (off < count) {           /* double-NUL terminate the stream */
		buf[off] = '\0';
		if (off + 1 < count)
			buf[off + 1] = '\0';
	} else {
		buf[count - 1] = '\0';
	}
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

	all = malloc(256 * 1024);
	if (!all) { pthread_mutex_unlock(&g_lock); return -1; }

	/* getall (re-enter would deadlock; inline a lock-free dump) */
	{
		int index = 0, off = 0, cap = 256 * 1024;
		for (;;) {
			int req[2]; unsigned short t = 0; int plen;
			req[0] = cap; req[1] = index;
			if (nl_send(WLCSM_MSG_NVRAM_GETALL, req, sizeof(req)) < 0) break;
			plen = nl_recv(&t, all + off, cap - off);
			if (plen < 0) break;
			off += (plen < cap - off) ? plen : (cap - off);
			if (t == WLCSM_MSG_NVRAM_GETALL_DONE || off >= cap) break;
			index++;
		}
		n = off;
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
