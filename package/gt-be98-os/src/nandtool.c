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
 *   gt-be98-nandtool pebdiff A B ERASESIZE PEBMAP
 *       A and B are data-only dumps (no OOB) of the same partition. Lists
 *       every eraseblock whose content differs, with its owner in PEBMAP
 *       (a "pebmap" listing of A), then a per-owner summary.
 *   gt-be98-nandtool flipzero IN OUT WRITESIZE OOBSIZE NBITS
 *       (simulation only) copy the one-page raw dump IN to OUT with NBITS
 *       data bits of the first 512-byte sector changed from 1 to 0, i.e.
 *       NBITS bitflips that a raw re-program of the page produces on NAND.
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

static int pebdiff(const char *fa, const char *fb, unsigned eb, const char *map)
{
	FILE *a = fopen(fa, "rb"), *b = fopen(fb, "rb"), *m = fopen(map, "r");
	static char owner[65536][32];
	char line[128];
	unsigned char *ba, *bb;
	unsigned long peb = 0, ndiff = 0, nfree = 0, nother = 0;
	unsigned long per_vol[256] = { 0 };
	unsigned p, v, l;

	if (!a || !b || !m || !eb) {
		fprintf(stderr, "pebdiff: cannot open the inputs\n");
		return 1;
	}
	while (fgets(line, sizeof(line), m)) {
		if (sscanf(line, "PEB %u vol %u lnum %u", &p, &v, &l) == 3 && p < 65536)
			snprintf(owner[p], sizeof(owner[p]), "vol %u lnum %u", v, l);
		else if (sscanf(line, "PEB %u", &p) == 1 && p < 65536) {
			char *w = strchr(line, ' ');

			w = w ? strchr(w + 1, ' ') : NULL;
			snprintf(owner[p], sizeof(owner[p]), "%s", w ? w + 1 : "?");
			owner[p][strcspn(owner[p], "\n")] = 0;
		}
	}
	ba = malloc(eb);
	bb = malloc(eb);
	while (fread(ba, 1, eb, a) == eb && fread(bb, 1, eb, b) == eb) {
		if (memcmp(ba, bb, eb)) {
			const char *o = peb < 65536 && owner[peb][0] ? owner[peb] : "?";

			printf("changed PEB %lu (%s)\n", peb, o);
			ndiff++;
			if (sscanf(o, "vol %u", &v) == 1 && v < 256)
				per_vol[v]++;
			else if (!strcmp(o, "free"))
				nfree++;
			else
				nother++;
		}
		peb++;
	}
	printf("pebdiff summary: %lu PEBs compared, %lu changed: free %lu other %lu",
	       peb, ndiff, nfree, nother);
	for (v = 0; v < 256; v++)
		if (per_vol[v])
			printf(" vol%u %lu", v, per_vol[v]);
	printf("\n");
	return 0;
}

static int flipzero(const char *in, const char *out, unsigned ws, unsigned oob,
		    unsigned n)
{
	FILE *i = fopen(in, "rb"), *o = fopen(out, "wb");
	unsigned char *b = malloc(ws + oob);
	unsigned pos, bit, done = 0;

	if (!i || !o || fread(b, 1, ws + oob, i) != ws + oob) {
		fprintf(stderr, "flipzero: bad input\n");
		return 1;
	}
	/* one bit per byte, spread over the sector (every 32 bytes) */
	for (pos = 0; pos < 512 && done < n; pos += 32) {
		for (bit = 0; bit < 8; bit++) {
			if (b[pos] & (1u << bit)) {
				b[pos] &= ~(1u << bit);
				done++;
				break;
			}
		}
	}
	fwrite(b, 1, ws + oob, o);
	fclose(o);
	printf("flipzero: %u bits cleared in sector 0\n", done);
	return done == n ? 0 : 1;
}

int main(int argc, char **argv)
{
	if (argc == 7 && !strcmp(argv[1], "flipzero"))
		return flipzero(argv[2], argv[3], strtoul(argv[4], NULL, 0),
				strtoul(argv[5], NULL, 0), strtoul(argv[6], NULL, 0));
	if (argc == 6 && !strcmp(argv[1], "pebdiff"))
		return pebdiff(argv[2], argv[3], strtoul(argv[4], NULL, 0), argv[5]);
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
		"       gt-be98-nandtool pebdiff A B ERASESIZE PEBMAP\n"
		"       gt-be98-nandtool data|oob DUMP WRITESIZE OOBSIZE\n");
	return 2;
}
