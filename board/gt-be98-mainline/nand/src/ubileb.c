// SPDX-License-Identifier: GPL-2.0
/*
 * gt-be98-ubileb - write whole LEBs of a UBI volume with the atomic LEB
 * change ioctl (UBI_IOCEBCH). Unlike ubiupdatevol it never touches the
 * volume table (no update marker), so it works inside a UBI write fence.
 *
 *   gt-be98-ubileb write /dev/ubiX_Y FILE      LEB i <- FILE bytes [i*LEB, (i+1)*LEB)
 *   gt-be98-ubileb lebsize /dev/ubiX_Y
 *   gt-be98-ubileb markbad /dev/mtdN OFFSET   (fence test: must be refused)
 */
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>
#include <mtd/ubi-user.h>
#include <mtd/mtd-user.h>

static long lebsize(const char *dev)
{
	char p[128], buf[32];
	unsigned ubi, vol;
	FILE *f;

	if (sscanf(dev, "/dev/ubi%u_%u", &ubi, &vol) != 2)
		return -1;
	snprintf(p, sizeof(p), "/sys/class/ubi/ubi%u_%u/usable_eb_size", ubi, vol);
	f = fopen(p, "r");
	if (!f || !fgets(buf, sizeof(buf), f))
		return -1;
	fclose(f);
	return strtol(buf, NULL, 0);
}

int main(int argc, char **argv)
{
	long leb;

	if (argc == 3 && !strcmp(argv[1], "lebsize")) {
		leb = lebsize(argv[2]);
		if (leb < 0)
			return 1;
		printf("%ld\n", leb);
		return 0;
	}
	if (argc == 4 && !strcmp(argv[1], "markbad")) {
		int fd = open(argv[2], O_RDWR);
		long long ofs = strtoll(argv[3], NULL, 0);

		if (fd < 0 || ioctl(fd, MEMSETBADBLOCK, &ofs) < 0) {
			fprintf(stderr, "ubileb: markbad %s 0x%llx: %s\n", argv[2], ofs,
				strerror(errno));
			return 2;
		}
		printf("marked bad\n");
		return 0;
	}
	if (argc == 4 && !strcmp(argv[1], "write")) {
		FILE *in = fopen(argv[3], "rb");
		int fd = open(argv[2], O_RDWR);
		char *buf;
		int lnum = 0;
		size_t n;

		leb = lebsize(argv[2]);
		if (!in || fd < 0 || leb <= 0) {
			fprintf(stderr, "ubileb: cannot open %s / %s\n", argv[2], argv[3]);
			return 1;
		}
		buf = malloc(leb);
		while ((n = fread(buf, 1, leb, in)) > 0) {
			struct ubi_leb_change_req req = {
				.lnum = lnum, .bytes = (int32_t)n, .dtype = 3,
			};

			if (ioctl(fd, UBI_IOCEBCH, &req) < 0 ||
			    write(fd, buf, n) != (ssize_t)n) {
				fprintf(stderr, "ubileb: LEB %d: %s\n", lnum, strerror(errno));
				return 2;
			}
			printf("LEB %d: %zu bytes\n", lnum, n);
			lnum++;
		}
		return 0;
	}
	fprintf(stderr, "usage: gt-be98-ubileb write /dev/ubiX_Y FILE | lebsize /dev/ubiX_Y | markbad /dev/mtdN OFFSET\n");
	return 1;
}
