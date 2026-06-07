/*
 * gt-be98 open libnvram - public API (subset of the vendor libnvram.so ABI).
 * SPDX-License-Identifier: GPL-2.0
 */
#ifndef GT_BE98_NVRAM_H
#define GT_BE98_NVRAM_H

#ifdef __cplusplus
extern "C" {
#endif

int   nvram_init(void *unused);
char *nvram_get(const char *name);
int   nvram_set(const char *name, const char *value);
int   nvram_unset(const char *name);
int   nvram_getall(char *buf, int count);
int   nvram_commit(void);
/* Unconditional persist (ignores the process-local dirty flag) - the CLI
 * `commit` verb uses this so a standalone cross-process commit always writes. */
int   nvram_commit_force(void);
int   nvram_kset(const char *name, const char *value);
int   nvram_kcommit(void);
int   nvram_commit_reqd(void);

/* Bitflag accessors over a hex-string nvram var (vendor ABI: rc imports
 * nvram_get_bitflag). bit must be 0..31. */
char *nvram_get_bitflag(const char *name, int bit);
int   nvram_set_bitflag(const char *name, int bit, int set);

/* wlcsm_* aliases (closed-consumer compatibility) */
char *wlcsm_nvram_get(const char *name);
int   wlcsm_nvram_set(const char *name, const char *value);
int   wlcsm_nvram_unset(const char *name);
int   wlcsm_nvram_getall(char *buf, int count);
int   wlcsm_nvram_commit(void);
int   wlcsm_nvram_commit_force(void);
char *wlcsm_nvram_get_bitflag(const char *name, int bit);
int   wlcsm_nvram_set_bitflag(const char *name, int bit, int set);

#ifdef __cplusplus
}
#endif

#endif /* GT_BE98_NVRAM_H */
