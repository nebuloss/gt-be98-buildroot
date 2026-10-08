// SPDX-License-Identifier: GPL-2.0
/*
 * devmem - read/write physical memory through /dev/mem (BusyBox-compatible
 * syntax), with one GT-BE98 guard.
 *
 *   devmem ADDRESS [WIDTH [VALUE]]      WIDTH: 8, 16, 32 (default) or 64
 *
 * Guard: 0xff802628 is the boot-state register. Bits [15:0] hold the boot
 * reason; setting the "boot once" request there would make every reset boot
 * the trial image again, so the mainline OS may only ever change bits
 * [31:24] (the post-code byte). A write to that word (or any write that
 * overlaps it) that would change bits [23:0] is refused. --force does not
 * exist on purpose.
 */
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#define BOOTSTATE_REG	0xff802628ULL
#define BOOTSTATE_KEEP	0x00ffffffU

static void usage(void)
{
	fprintf(stderr, "usage: devmem ADDRESS [WIDTH [VALUE]]\n"
		"  WIDTH: 8, 16, 32 (default) or 64 bits\n");
	exit(2);
}

static int parse_u64(const char *s, uint64_t *v)
{
	char *end;

	errno = 0;
	*v = strtoull(s, &end, 0);
	return errno || *end || end == s ? -1 : 0;
}

int main(int argc, char **argv)
{
	uint64_t addr, val = 0, width = 32;
	long pg = sysconf(_SC_PAGESIZE);
	unsigned int bytes;
	int fd, wr = 0;
	void *map;
	volatile uint8_t *p;
	off_t base;
	size_t off;

	if (argc < 2 || argc > 4 || parse_u64(argv[1], &addr))
		usage();
	if (argc >= 3 && parse_u64(argv[2], &width))
		usage();
	if (width != 8 && width != 16 && width != 32 && width != 64)
		usage();
	bytes = width / 8;
	if (addr % bytes) {
		fprintf(stderr, "devmem: 0x%" PRIx64 " not aligned to %u bytes\n",
			addr, bytes);
		return 1;
	}
	if (argc == 4) {
		if (parse_u64(argv[3], &val))
			usage();
		wr = 1;
	}

	fd = open("/dev/mem", (wr ? O_RDWR : O_RDONLY) | O_SYNC);
	if (fd < 0) {
		perror("devmem: /dev/mem");
		return 1;
	}
	base = (off_t)(addr & ~((uint64_t)pg - 1));
	off = addr - (uint64_t)base;
	map = mmap(NULL, off + bytes, wr ? PROT_READ | PROT_WRITE : PROT_READ,
		   MAP_SHARED, fd, base);
	if (map == MAP_FAILED) {
		perror("devmem: mmap");
		return 1;
	}
	p = (volatile uint8_t *)map + off;

	if (wr && addr < BOOTSTATE_REG + 4 && addr + bytes > BOOTSTATE_REG) {
		uint32_t cur, next;

		if (addr != BOOTSTATE_REG || width != 32) {
			fprintf(stderr, "devmem: refused: 0x%llx may only be written "
				"as one 32-bit word\n", BOOTSTATE_REG);
			return 1;
		}
		cur = *(volatile uint32_t *)p;
		next = (uint32_t)val;
		if ((cur ^ next) & BOOTSTATE_KEEP) {
			fprintf(stderr, "devmem: refused: 0x%llx bits [23:0] must not "
				"change (now 0x%08x, asked 0x%08x); only the post-code "
				"byte [31:24] may be written\n", BOOTSTATE_REG, cur, next);
			return 1;
		}
	}

	if (wr) {
		switch (width) {
		case 8:  *(volatile uint8_t *)p = (uint8_t)val; break;
		case 16: *(volatile uint16_t *)p = (uint16_t)val; break;
		case 32: *(volatile uint32_t *)p = (uint32_t)val; break;
		case 64: *(volatile uint64_t *)p = val; break;
		}
	} else {
		switch (width) {
		case 8:  val = *(volatile uint8_t *)p; break;
		case 16: val = *(volatile uint16_t *)p; break;
		case 32: val = *(volatile uint32_t *)p; break;
		case 64: val = *(volatile uint64_t *)p; break;
		}
		printf("0x%0*" PRIX64 "\n", (int)(bytes * 2), val);
	}
	munmap(map, off + bytes);
	close(fd);
	return 0;
}
