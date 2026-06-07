/*
 * gt-be98 open nvram CLI - thin front-end over the open libnvram
 * (NETLINK_WLCSM client). Verb set mirrors the vendor /bin/nvram:
 *   get <name> | set <name=value> | unset <name> | show | getall | commit
 *   kernelset [file] | restore_mfg [file]
 *
 * kernelset/restore_mfg reproduce the verbs the boot script hndnvram.sh calls
 * at S40 (populate_nvram / nvram_mfg_restore_default) to bring the in-kernel
 * tuple tree up from the persisted file on disk. Without them the kernel tree
 * stays empty on boot and every persisted setting reads back NULL.
 * SPDX-License-Identifier: GPL-2.0
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include "nvram.h"

#define GETALL_BUF (256 * 1024)

/* The persisted kernel-nvram file, and the manufacturing default sources. These
 * match the (retained, byte-identical) hndnvram.sh and the vendor /bin/nvram.
 * Overridable at compile time only for the offline test harness. */
#ifndef KERNEL_NVRAM_FILE
#define KERNEL_NVRAM_FILE  "/data/.kernel_nvram.setting"
#endif
#ifndef MFG_NVRAM_FILE
#define MFG_NVRAM_FILE     "/mnt/nvram/nvram.nvm"
#endif
#ifndef BASE_MAC_PROC
#define BASE_MAC_PROC      "/proc/nvram/BaseMacAddr"
#endif
#define LINE_MAX_LEN       1024

static int do_show(void)
{
	char *buf = malloc(GETALL_BUF);
	int n, p;
	if (!buf)
		return 1;
	n = nvram_getall(buf, GETALL_BUF);
	if (n < 0) { free(buf); return 1; }
	for (p = 0; p < n; ) {
		int l = (int)strlen(buf + p);
		if (l == 0) { p++; continue; }
		printf("%s\n", buf + p);
		p += l + 1;
	}
	free(buf);
	return 0;
}

/* Strip leading and trailing whitespace from s in place; return s. */
static char *trim(char *s)
{
	char *e;
	while (*s && isspace((unsigned char)*s))
		s++;
	e = s + strlen(s);
	while (e > s && isspace((unsigned char)e[-1]))
		*--e = '\0';
	return s;
}

/*
 * kernelset: populate the in-kernel nvram tree from a persisted "name=value"
 * file (default KERNEL_NVRAM_FILE). Mirrors the vendor verb:
 *   - one entry per line, lines starting with '#' are comments (skipped),
 *   - the name is everything before the first '=', the value everything after
 *     (so values may themselves contain '='),
 *   - lines without a '=' are skipped,
 *   - each pair is pushed with nvram_set (RAM-only; NO commit - the kernel
 *     COMMIT/flash write is a separate, later step).
 * The file format is the exact round-trip of nvram_commit's writer
 * ("name=value\n"), so a committed file re-populates the identical key set.
 */
static int do_kernelset(const char *file)
{
	char line[LINE_MAX_LEN];
	FILE *f;

	if (!file)
		file = KERNEL_NVRAM_FILE;
	f = fopen(file, "r");
	if (!f)
		return 1;
	while (fgets(line, sizeof(line), f)) {
		char *eq, *name, *value;
		if (line[0] == '#')
			continue;            /* comment */
		eq = strchr(line, '=');
		if (!eq)
			continue;            /* no name=value separator */
		*eq = '\0';
		value = eq + 1;
		/* strip the trailing newline fgets keeps; preserve the rest verbatim */
		value[strcspn(value, "\r\n")] = '\0';
		name = trim(line);
		if (!*name)
			continue;
		nvram_set(name, value);
	}
	fclose(f);
	printf("popuplate nvram from %s done!\n", file);
	return 0;
}

/*
 * restore_mfg: rebuild the persisted kernel-nvram file from the manufacturing
 * defaults. Reproduces the vendor verb hndnvram.sh calls on a factory-clean
 * unit (when KERNEL_NVRAM_FILE is absent and the mfg partition is mounted):
 *   - read the mfg defaults from MFG_NVRAM_FILE (NUL-separated "name=value"
 *     entries) and APPEND each as a "name=value\n" line to <file>,
 *   - if the mfg set carries no et0macaddr, append et0macaddr taken from the
 *     authoritative kernel node BASE_MAC_PROC (this is the device's real
 *     per-unit MAC, never synthesized - it is only read, never defaulted).
 * This writes the FILE only; it does not touch the kernel tree (the following
 * kernelset loads the merged file). <file> defaults to KERNEL_NVRAM_FILE.
 */
static int do_restore_mfg(const char *file)
{
	FILE *src, *dst;
	char entry[LINE_MAX_LEN];
	int c, len = 0, have_mac = 0, overflow = 0;

	if (!file)
		file = KERNEL_NVRAM_FILE;
	printf("Restoring NVRAM to manufacturing default ... ");

	src = fopen(MFG_NVRAM_FILE, "rb");
	if (!src) {
		printf("fail.\n");
		return 1;
	}
	dst = fopen(file, "a");
	if (!dst) {
		fclose(src);
		printf("fail.\n");
		return 1;
	}

	/* mfg file is a stream of NUL-separated "name=value" entries */
	while ((c = fgetc(src)) != EOF) {
		if (c != '\0') {
			if (len < LINE_MAX_LEN - 1) {
				entry[len++] = (char)c;
			} else {
				overflow = 1;
				break;
			}
			continue;
		}
		entry[len] = '\0';
		if (len > 0) {
			if (!strncmp(entry, "et0macaddr=", 11))
				have_mac = 1;
			fprintf(dst, "%s\n", entry);
		}
		len = 0;
	}

	/* No et0macaddr in the mfg set: take the authoritative MAC from the
	 * kernel BaseMacAddr node. Read-only of the real per-unit value. */
	if (!overflow && !have_mac) {
		FILE *mf = fopen(BASE_MAC_PROC, "rb");
		if (mf) {
			char mac[18];
			size_t r = fread(mac, 1, sizeof(mac) - 1, mf);
			if (r > 0) {
				mac[r] = '\0';
				mac[strcspn(mac, "\r\n")] = '\0';
				fprintf(dst, "et0macaddr=%s\n", mac);
			}
			fclose(mf);
		}
	}

	fclose(dst);
	fclose(src);
	printf(overflow ? "fail.\n" : "done.\n");
	return overflow ? 1 : 0;
}

/*
 * Bitflag verbs over a hex-string nvram var (one bit of bits 0..31).
 *
 * The stock /bin/nvram (confirmed by disassembly of the closed binary) exposes
 * these as `getflag`/`setflag` with this exact arg shape:
 *     nvram getflag <name> <bit>          -> get_bitflag(name, atoi(bit))
 *     nvram setflag <name> <bit>=<value>  -> set_bitflag(name, atoi(bit), atoi(value))
 * setflag's second token is a single "bit=value" argument (strsep on '='), and
 * the verb prints the resulting var value. We reproduce both verbs faithfully.
 *
 * For completeness we ALSO accept the conventional separated-argument spellings
 * `get_bitflag`/`set_bitflag` (the library symbol names) so callers/scripts that
 * use either form dispatch correctly instead of falling through to usage:
 *     nvram get_bitflag <name> <bit>
 *     nvram set_bitflag <name> <bit> <0|1>
 * NOTE: no boot/rootfs script invokes any of these CLI verbs (grep of
 * p3step0/root + hndnvram.sh + services-start found none) - they are not
 * boot-critical; the in-process consumers use the library symbols directly.
 */
static int do_getflag(const char *name, const char *bit)
{
	char *v = nvram_get_bitflag(name, atoi(bit));
	if (v)
		printf("%s\n", v);
	return 0;
}

static int do_setflag(const char *name, int bit, int value)
{
	char *v;
	(void)nvram_set_bitflag(name, bit, value ? 1 : 0);
	v = nvram_get(name);
	if (v)
		printf("%s\n", v);
	return 0;
}

static void usage(void)
{
	fprintf(stderr,
		"usage: nvram [get name] [set name=value] [unset name] "
		"[show|getall] [commit] [kernelset [file]] [restore_mfg [file]] "
		"[getflag name bit] [setflag name bit=value] "
		"[get_bitflag name bit] [set_bitflag name bit 0|1]\n");
}

int main(int argc, char **argv)
{
	if (argc < 2) { usage(); return 1; }

	if (!strcmp(argv[1], "get") && argc == 3) {
		char *v = nvram_get(argv[2]);
		if (v) printf("%s\n", v);
		return 0;
	}
	if (!strcmp(argv[1], "set") && argc == 3) {
		char *eq = strchr(argv[2], '=');
		if (!eq) { usage(); return 1; }
		*eq = '\0';
		return nvram_set(argv[2], eq + 1) ? 1 : 0;
	}
	if (!strcmp(argv[1], "unset") && argc == 3)
		return nvram_unset(argv[2]) ? 1 : 0;
	if (!strcmp(argv[1], "commit") && argc == 2)
		/* explicit, cross-process commit: ALWAYS persist (stock semantics).
		 * A standalone `nvram commit` runs in its own process with an empty
		 * dirty flag, so the plain nvram_commit() early-return would write
		 * nothing and silently lose an earlier `nvram set`. */
		return nvram_commit_force() ? 1 : 0;
	if ((!strcmp(argv[1], "show") || !strcmp(argv[1], "getall")) && argc == 2)
		return do_show();
	if (!strcmp(argv[1], "kernelset") && (argc == 2 || argc == 3))
		return do_kernelset(argc == 3 ? argv[2] : NULL);
	if (!strcmp(argv[1], "restore_mfg") && (argc == 2 || argc == 3))
		return do_restore_mfg(argc == 3 ? argv[2] : NULL);
	/* stock-exact: getflag <name> <bit> */
	if (!strcmp(argv[1], "getflag") && argc == 4)
		return do_getflag(argv[2], argv[3]);
	/* stock-exact: setflag <name> <bit>=<value> (one "bit=value" token) */
	if (!strcmp(argv[1], "setflag") && argc == 4) {
		char *eq = strchr(argv[3], '=');
		if (!eq) { usage(); return 1; }
		*eq = '\0';
		return do_setflag(argv[2], atoi(argv[3]), atoi(eq + 1));
	}
	/* conventional aliases (library symbol names): separated args */
	if (!strcmp(argv[1], "get_bitflag") && argc == 4)
		return do_getflag(argv[2], argv[3]);
	if (!strcmp(argv[1], "set_bitflag") && argc == 5)
		return do_setflag(argv[2], atoi(argv[3]), atoi(argv[4]));

	usage();
	return 1;
}
