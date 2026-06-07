/*
 * gt-be98 open nvram CLI - thin front-end over the open libnvram
 * (NETLINK_WLCSM client). Verb set mirrors the vendor /bin/nvram:
 *   get <name> | set <name=value> | unset <name> | show | getall | commit
 * SPDX-License-Identifier: GPL-2.0
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "nvram.h"

#define GETALL_BUF (256 * 1024)

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

static void usage(void)
{
	fprintf(stderr,
		"usage: nvram [get name] [set name=value] [unset name] "
		"[show|getall] [commit]\n");
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
		return nvram_commit() ? 1 : 0;
	if ((!strcmp(argv[1], "show") || !strcmp(argv[1], "getall")) && argc == 2)
		return do_show();

	usage();
	return 1;
}
