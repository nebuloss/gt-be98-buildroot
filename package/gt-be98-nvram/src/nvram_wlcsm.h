/*
 * gt-be98 open libnvram - NETLINK_WLCSM protocol constants
 *
 * Reproduced from the OPEN GPL kernel header
 *   src-rt-5.04behnd.4916/bcmdrivers/opensource/char/bcm_knvram/impl1/include/wlcsm_linux.h
 * and bcm_netlink.h (NETLINK_WLCSM == 31). These are the byte-for-byte
 * definitions used by the in-kernel bcm_knvram.ko netlink server, so a
 * userspace client built against them is wire-compatible with the running
 * kernel store. No closed surface.
 *
 * SPDX-License-Identifier: GPL-2.0
 */
#ifndef GT_BE98_NVRAM_WLCSM_H
#define GT_BE98_NVRAM_WLCSM_H

#include <stdint.h>
#include <string.h>

/* bcm_netlink.h:38 */
#define NETLINK_WLCSM            31

/* wlcsm_linux.h caps */
#define WLCSM_NAMEVALUEPAIR_MAX  1024
#define NL_PACKET_SIZE           WLCSM_NAMEVALUEPAIR_MAX
#define MAX_NLRCV_BUF_SIZE       1280

/* wlcsm_linux.h:121 - on-wire message header that follows the nlmsghdr */
typedef struct wlcsm_msg_hdr {
	unsigned short type;
	unsigned short len;
	unsigned int   pid;
} t_WLCSM_MSG_HDR;

/* wlcsm_linux.h:133 - message types (default build, no WLCSM_DEBUG => no
 * ordinal shift; matches the shipped non-debug bcm_knvram.ko). */
enum wlcsm_msgtype {
	WLCSM_MSG_BASE = 0,
	WLCSM_MSG_REGISTER,
	WLCSM_MSG_NVRAM_SET,        /* 2 */
	WLCSM_MSG_NVRAM_GET,        /* 3 */
	WLCSM_MSG_NVRAM_UNSET,      /* 4 */
	WLCSM_MSG_NVRAM_GETALL,     /* 5 */
	WLCSM_MSG_NVRAM_GETALL_DONE,/* 6 */
	WLCSM_MSG_NVRAM_COMMIT,     /* 7 */
	WLCSM_MSG_GETWL_BASE,
	WLCSM_MSG_GETWL_VAR,
	WLCSM_MSG_GETWL_VAR_RESP,
	WLCSM_MSG_GETWL_VAR_RESP_DONE,
	WLCSM_MSG_SETWL_VAR,
	WLCSM_MSG_SETWL_VAR_RESP,
	WLCSM_MSG_NVRAM_XFR,
	WLCSM_MSG_DUMP_PREV_OOPS,
};

/*
 * name/value pair packing - byte-identical to wlcsm_linux.h inline helpers and
 * the kernel _valuepair_set() (wlcsm_nvram.c:55). Layout of a packed pair:
 *
 *   off 0                : int  name_len   (= strlen(name)+1, NOT aligned)
 *   off 4                : char name[]     (NUL terminated)
 *   off 4+align4(nlen)   : int  value_len  (= strlen(value)+1, or 0)
 *   off 8+align4(nlen)   : char value[]
 *
 * total = 2*sizeof(int) + align4(name_len) + value_len
 */
static inline int wlcsm_aligned_namelen(const char *name)
{
	int nlen = (int)strlen(name) + 1;
	int mod  = nlen & (int)(sizeof(int) - 1);
	return mod ? ((nlen + (int)sizeof(int)) & ~(int)(sizeof(int) - 1)) : nlen;
}

static inline int wlcsm_pair_total_len(const char *name, const char *value)
{
	int vlen = value ? (int)strlen(value) + 1 : 0;
	return 2 * (int)sizeof(int) + wlcsm_aligned_namelen(name) + vlen;
}

/* Pack name/value into buf (caller-sized via wlcsm_pair_total_len).
 * Returns total length. value==NULL => unset-style pair (value_len 0). */
static inline int wlcsm_pair_pack(char *buf, const char *name, const char *value)
{
	int total = wlcsm_pair_total_len(name, value);
	int an = wlcsm_aligned_namelen(name);
	memset(buf, 0, total);
	*(int *)buf = (int)strlen(name) + 1;     /* name_len field */
	strcpy(buf + sizeof(int), name);         /* name */
	if (value) {
		char *vp = buf + sizeof(int) + an;
		*(int *)vp = (int)strlen(value) + 1; /* value_len field */
		memcpy(vp + sizeof(int), value, strlen(value) + 1);
	}
	return total;
}

/* Extract the value pointer/len out of a packed pair returned by GET.
 * Returns value pointer (into buf) and writes its length (incl NUL) to *vlen,
 * or NULL if the pair carries no value. */
static inline const char *wlcsm_pair_value(const char *buf, int *vlen)
{
	int name_len = *(const int *)buf;            /* strlen(name)+1 */
	int an;
	const char *name = buf + sizeof(int);
	const int *vlp;
	(void)name_len;
	an = wlcsm_aligned_namelen(name);
	vlp = (const int *)(buf + sizeof(int) + an);
	if (*vlp <= 0) { if (vlen) *vlen = 0; return NULL; }
	if (vlen) *vlen = *vlp;
	return (const char *)(vlp + 1);
}

#endif /* GT_BE98_NVRAM_WLCSM_H */
