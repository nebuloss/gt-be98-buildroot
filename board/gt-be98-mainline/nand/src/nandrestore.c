// SPDX-License-Identifier: GPL-2.0
/*
 * gt-be98-nandrestore - restore a raw NAND backup, PEB by PEB, bit-exact.
 *
 *   gt-be98-nandrestore [--dry-run] [--peb N] BACKUP /dev/mtdM
 *
 * BACKUP is a "nanddump --noecc --oob --bb=dumpbad" dump of the whole MTD
 * device M (page data + OOB as the controller presents them in raw mode,
 * page after page). For every eraseblock, the current raw content is read
 * back (MTD_OPS_RAW) and compared; only eraseblocks that differ are
 * rewritten: erase, then every page that is not blank in the backup is
 * programmed raw (data + OOB, so the original ECC bytes go back unchanged),
 * then read back and compared again. Identical eraseblocks are not touched.
 *
 * Writes go through the GT-BE98 write fence: for each eraseblock the tool
 * registers itself in /sys/kernel/debug/ubi/fence_restore ("add M PEB 1"),
 * which the kernel refuses while any UBI device is attached to that chip,
 * and drops the entry afterwards ("clear"). On the box this also needs
 * brcmnand.allow_write=1 (/sys/module/brcmnand/parameters/allow_write) and
 * an MTD partition that is not read-only (an image built with NAND=rw-jffs).
 * Bad eraseblocks (now or in the backup) are reported and skipped.
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

#define FENCE_CTL "/sys/kernel/debug/ubi/fence_restore"

static int fence(const char *cmd)
{
	int fd = open(FENCE_CTL, O_WRONLY);
	ssize_t n;

	if (fd < 0) {
		perror(FENCE_CTL);
		return -1;
	}
	n = write(fd, cmd, strlen(cmd));
	if (n < 0)
		fprintf(stderr, "fence_restore \"%s\": %s\n", cmd, strerror(errno));
	close(fd);
	return n < 0 ? -1 : 0;
}

static int raw_io(int fd, int wr, uint64_t ofs, unsigned char *dat, unsigned ws,
		  unsigned char *oob, unsigned oobsz)
{
	struct mtd_write_req req;

	memset(&req, 0, sizeof(req));
	req.start = ofs;
	req.len = ws;
	req.ooblen = oobsz;
	req.usr_data = (uintptr_t)dat;
	req.usr_oob = (uintptr_t)oob;
	req.mode = MTD_OPS_RAW;
	if (wr)
		return ioctl(fd, MEMWRITE, &req);
	{
		struct mtd_read_req rr;

		memset(&rr, 0, sizeof(rr));
		rr.start = ofs;
		rr.len = ws;
		rr.ooblen = oobsz;
		rr.usr_data = (uintptr_t)dat;
		rr.usr_oob = (uintptr_t)oob;
		rr.mode = MTD_OPS_RAW;
		if (ioctl(fd, MEMREAD, &rr) < 0)
			return -1;
		return 0;
	}
}

static int blank(const unsigned char *p, unsigned n)
{
	while (n--)
		if (*p++ != 0xff)
			return 0;
	return 1;
}

int main(int argc, char **argv)
{
	int dry = 0, only = -1, fd, mtdn, i;
	const char *bk, *dev;
	struct mtd_info_user mi;
	FILE *b;
	unsigned ws, oob, ppb, rec, peb, nblocks, page;
	unsigned long changed = 0, rewritten = 0, failed = 0, bad = 0;
	unsigned char *bbuf, *cbuf;

	for (i = 1; i < argc && argv[i][0] == '-'; i++) {
		if (!strcmp(argv[i], "--dry-run"))
			dry = 1;
		else if (!strcmp(argv[i], "--peb") && i + 1 < argc)
			only = atoi(argv[++i]);
		else
			goto usage;
	}
	if (argc - i != 2)
		goto usage;
	bk = argv[i];
	dev = argv[i + 1];
	if (sscanf(dev, "/dev/mtd%d", &mtdn) != 1)
		goto usage;

	fd = open(dev, dry ? O_RDONLY : O_RDWR);
	if (fd < 0 || ioctl(fd, MEMGETINFO, &mi)) {
		perror(dev);
		return 1;
	}
	ws = mi.writesize;
	oob = mi.oobsize;
	ppb = mi.erasesize / ws;
	rec = ws + oob;
	nblocks = mi.size / mi.erasesize;
	b = fopen(bk, "rb");
	if (!b) {
		perror(bk);
		return 1;
	}
	fseek(b, 0, SEEK_END);
	if ((unsigned long)ftell(b) != (unsigned long)nblocks * ppb * rec) {
		fprintf(stderr, "%s: size %ld, expected %lu (%u blocks x %u pages x (%u+%u))\n",
			bk, ftell(b), (unsigned long)nblocks * ppb * rec, nblocks, ppb, ws, oob);
		return 1;
	}
	printf("# %s: %u blocks, %u pages of %u+%u, %s\n", dev, nblocks, ppb, ws, oob,
	       dry ? "DRY RUN" : "restoring");
	bbuf = malloc((size_t)ppb * rec);
	cbuf = malloc((size_t)ppb * rec);

	for (peb = 0; peb < nblocks; peb++) {
		loff_t ofs = (loff_t)peb * mi.erasesize;
		struct erase_info_user64 ei = { .start = ofs, .length = mi.erasesize };
		char cmd[64];
		int diff = 0, err = 0;

		if (only >= 0 && (int)peb != only)
			continue;
		fseek(b, (long)peb * ppb * rec, SEEK_SET);
		if (fread(bbuf, 1, (size_t)ppb * rec, b) != (size_t)ppb * rec) {
			fprintf(stderr, "short read of the backup at PEB %u\n", peb);
			return 1;
		}
		if (ioctl(fd, MEMGETBADBLOCK, &ofs) > 0) {
			printf("PEB %u bad now: skipped\n", peb);
			bad++;
			continue;
		}
		for (page = 0; page < ppb; page++) {
			unsigned char *c = cbuf + (size_t)page * rec;

			if (raw_io(fd, 0, ofs + (uint64_t)page * ws, c, ws, c + ws, oob)) {
				printf("PEB %u page %u: raw read error %d\n", peb, page, errno);
				diff = 1;
				break;
			}
			if (memcmp(c, bbuf + (size_t)page * rec, rec))
				diff = 1;
		}
		if (!diff)
			continue;
		changed++;
		printf("PEB %u differs%s\n", peb, dry ? "" : ": rewriting");
		if (dry)
			continue;

		snprintf(cmd, sizeof(cmd), "add %d %u 1", mtdn, peb);
		if (fence(cmd)) {
			failed++;
			break;
		}
		if (ioctl(fd, MEMERASE64, &ei)) {
			printf("PEB %u: erase failed: %s\n", peb, strerror(errno));
			err = 1;
		}
		for (page = 0; !err && page < ppb; page++) {
			unsigned char *p = bbuf + (size_t)page * rec;

			if (blank(p, rec))
				continue;	/* erased page in the backup */
			if (raw_io(fd, 1, ofs + (uint64_t)page * ws, p, ws, p + ws, oob)) {
				printf("PEB %u page %u: raw write failed: %s\n", peb, page,
				       strerror(errno));
				err = 1;
			}
		}
		fence("clear");
		for (page = 0; !err && page < ppb; page++) {
			unsigned char *c = cbuf + (size_t)page * rec;

			if (raw_io(fd, 0, ofs + (uint64_t)page * ws, c, ws, c + ws, oob) ||
			    memcmp(c, bbuf + (size_t)page * rec, rec)) {
				printf("PEB %u page %u: verify FAILED\n", peb, page);
				err = 1;
			}
		}
		if (err)
			failed++;
		else
			rewritten++;
	}
	printf("restore summary: %lu differing, %lu rewritten and verified, %lu failed, %lu bad skipped%s\n",
	       changed, rewritten, failed, bad, dry ? " (dry run)" : "");
	return failed ? 2 : 0;

usage:
	fprintf(stderr, "usage: gt-be98-nandrestore [--dry-run] [--peb N] BACKUP /dev/mtdN\n");
	return 1;
}
