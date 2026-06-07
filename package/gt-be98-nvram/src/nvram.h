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
int   nvram_kset(const char *name, const char *value);
int   nvram_kcommit(void);
int   nvram_commit_reqd(void);

/* wlcsm_* aliases (closed-consumer compatibility) */
char *wlcsm_nvram_get(const char *name);
int   wlcsm_nvram_set(const char *name, const char *value);
int   wlcsm_nvram_unset(const char *name);
int   wlcsm_nvram_getall(char *buf, int count);
int   wlcsm_nvram_commit(void);

#ifdef __cplusplus
}
#endif

#endif /* GT_BE98_NVRAM_H */
