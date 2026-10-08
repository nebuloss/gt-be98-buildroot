# SPDX-License-Identifier: GPL-2.0
CFLAGS ?= -O2
CFLAGS += -Wall -Wextra
all: devmem nandtool
devmem: devmem.c
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $<
clean:
	rm -f devmem nandtool
.PHONY: all clean
nandtool: nandtool.c
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $<
