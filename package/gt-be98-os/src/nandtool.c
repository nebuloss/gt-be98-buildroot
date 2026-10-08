// SPDX-License-Identifier: GPL-2.0
/*
 * gt-be98-nandtool - READ-ONLY NAND/UBI helpers for the stock vs mainline
 * ECC comparison (board/gt-be98-mainline/NAND.md). Builds statically for the
 * stock 4.19 firmware too. It only ever opens files read-only.
 *
 *   gt-be98-nandtool pebmap /dev/mtdN
 *       one line per eraseblock: "PEB <n> vol <id> lnum <l>" for a UBI VID
 *       header, "PEB <n> free" (EC header, no VID header), "PEB <n> nohdr",
 *       or "PEB <n> bad" / "PEB <n> readerr <errno>".
 *   gt-be98-nandtool flips RAW ECC WRITESIZE OOBSIZE
 *       RAW and ECC are "nanddump --oob" dumps of the same pages, RAW with
 *       -n (no ECC), ECC without. Per page with a difference:
 *       "page <i> erased <0|1> flips <n> maxsector <m> oobdiff <k>", then a
 *       summary line. A page is "erased" when its corrected data is all 0xff.
 *   gt-be98-nandtool data|oob DUMP WRITESIZE OOBSIZE
 *       write only the page data (or only the OOB) of a "nanddump --oob"
 *       dump to stdout (to compare dumps whose OOB sizes differ).
 */
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>
#include <mtd/mtd-user.h>

static uint32_t be32(const unsigned char *p)
{
	return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3];
}

static int pebmap(const char *dev)
{
	struct mtd_info_user mi;
	unsigned char h[64];
	int fd = open(dev, O_RDONLY);
	uint32_t n, peb;

	if (fd < 0 || ioctl(fd, MEMGETINFO, &mi)) {
		perror(dev);
		return 1;
	}
	n = mi.size / mi.erasesize;
	printf("# %s size %u erasesize %u writesize %u oobsize %u\n",
	       dev, mi.size, mi.erasesize, mi.writesize, mi.oobsize);
	for (peb = 0; peb < n; peb++) {
		loff_t off = (loff_t)peb * mi.erasesize;

		if (ioctl(fd, MEMGETBADBLOCK, &off) > 0) {
			printf("PEB %u bad\n", peb);
			continue;
		}
		if (pread(fd, h, sizeof(h), off) != (ssize_t)sizeof(h)) {
			printf("PEB %u readerr %d\n", peb, errno);
			continue;
		}
		if (memcmp(h, "UBI#", 4)) {
			printf("PEB %u nohdr\n", peb);
			continue;
		}
		/* VID header offset from the EC header (be32 at offset 16) */
		off += be32(h + 16);
		if (pread(fd, h, sizeof(h), off) != (ssize_t)sizeof(h)) {
			printf("PEB %u readerr %d\n", peb, errno);
			continue;
		}
		if (memcmp(h, "UBI!", 4)) {
			printf("PEB %u free\n", peb);
			continue;
		}
		printf("PEB %u vol %u lnum %u\n", peb, be32(h + 8), be32(h + 12));
	}
	close(fd);
	return 0;
}

static int popc(unsigned char x)
{
	return __builtin_popcount(x);
}

static int flips(const char *rawf, const char *eccf, unsigned ws, unsigned oob)
{
	FILE *r = fopen(rawf, "rb"), *e = fopen(eccf, "rb");
	unsigned char *rb, *eb;
	unsigned long pages = 0, erased = 0, pflips = 0, eflips = 0, oobd = 0;
	unsigned long dirty_p = 0, dirty_e = 0, worst = 0;
	unsigned i, s, sectors = ws / 512;

	if (!r || !e || !ws) {
		fprintf(stderr, "flips: cannot open the dumps\n");
		return 1;
	}
	rb = malloc(ws + oob);
	eb = malloc(ws + oob);
	while (fread(rb, 1, ws + oob, r) == ws + oob &&
	       fread(eb, 1, ws + oob, e) == ws + oob) {
		unsigned long f = 0, maxs = 0, od = 0;
		int is_erased = 1;

		for (s = 0; s < sectors; s++) {
			unsigned long fs = 0;

			for (i = s * 512; i < (s + 1) * 512; i++) {
				fs += popc(rb[i] ^ eb[i]);
				if (eb[i] != 0xff)
					is_erased = 0;
			}
			f += fs;
			if (fs > maxs)
				maxs = fs;
		}
		for (i = ws; i < ws + oob; i++)
			od += popc(rb[i] ^ eb[i]);
		if (f || od)
			printf("page %lu erased %d flips %lu maxsector %lu oobdiff %lu\n",
			       pages, is_erased, f, maxs, od);
		if (is_erased) {
			erased++;
			eflips += f;
			dirty_e += !!f;
		} else {
			pflips += f;
			dirty_p += !!f;
		}
		if (maxs > worst)
			worst = maxs;
		oobd += od;
		pages++;
	}
	printf("summary pages %lu erased %lu | programmed: pages_with_flips %lu flips %lu | "
	       "erased: pages_with_flips %lu flips %lu | worst_sector %lu | oob_bits_differing %lu\n",
	       pages, erased, dirty_p, pflips, dirty_e, eflips, worst, oobd);
	return 0;
}

static int split(const char *f, int want_oob, unsigned ws, unsigned oob)
{
	FILE *in = fopen(f, "rb");
	unsigned char *b;

	if (!in || !ws) {
		perror(f);
		return 1;
	}
	b = malloc(ws + oob);
	while (fread(b, 1, ws + oob, in) == ws + oob)
		fwrite(want_oob ? b + ws : b, 1, want_oob ? oob : ws, stdout);
	fclose(in);
	return 0;
}

int main(int argc, char **argv)
{
	if (argc == 5 && (!strcmp(argv[1], "data") || !strcmp(argv[1], "oob")))
		return split(argv[2], !strcmp(argv[1], "oob"), strtoul(argv[3], NULL, 0),
			     strtoul(argv[4], NULL, 0));
	if (argc == 3 && !strcmp(argv[1], "pebmap"))
		return pebmap(argv[2]);
	if (argc == 6 && !strcmp(argv[1], "flips"))
		return flips(argv[2], argv[3], strtoul(argv[4], NULL, 0),
			     strtoul(argv[5], NULL, 0));
	fprintf(stderr, "usage: gt-be98-nandtool pebmap /dev/mtdN\n"
		"       gt-be98-nandtool flips RAW ECC WRITESIZE OOBSIZE\n"
		"       gt-be98-nandtool data|oob DUMP WRITESIZE OOBSIZE\n");
	return 2;
}
