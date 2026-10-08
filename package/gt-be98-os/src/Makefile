# SPDX-License-Identifier: GPL-2.0
CFLAGS ?= -O2
CFLAGS += -Wall -Wextra
all: devmem
devmem: devmem.c
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $<
clean:
	rm -f devmem
.PHONY: all clean
