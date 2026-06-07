################################################################################
#
# gt-be98-libshared  (libshared.so, from source via the merlin SDK build-glue)
#
# Promotes the proven output-sdkglue harness into a Buildroot recipe. Builds the
# asuswrt router/shared library FROM SOURCE (58 open .c) against the Broadcom
# SDK include graph, exporting the merlin build env (SRCBASE / HND_SRC / the
# fully-expanded CFLAGS incl. -DGTBE98). The 15 closed + 4 SDK-buildable
# prebuild/*.o stay as pinned graft inputs (linked by the Makefile's prebuild
# rules); everything else is compiled here.
#
# Result is ABI-perfect against the device libshared.so: 1449/1449 exported
# symbols (0 diff), 197/197 undefined (0 diff), identical DT_NEEDED
# (libpthread/libc/ld-linux), ELF32 ARM EABI5. This is the from-source core
# that lets rc / hostapd link -lshared without the prebuilt blob.
#
# Requires the firmware tree (override with GT_BE98_LIBSHARED_MERLIN_ROOT). The
# build runs inside the SDK tree (router/shared, in-place, idempotent) and copies
# the artifact back into $(@D). Not wired into gt-be98_full_defconfig.
#
################################################################################

GT_BE98_LIBSHARED_VERSION = 1.0
GT_BE98_LIBSHARED_SITE = $(GT_BE98_LIBSHARED_PKGDIR)/src
GT_BE98_LIBSHARED_SITE_METHOD = local
GT_BE98_LIBSHARED_LICENSE = PROPRIETARY (asuswrt-merlin shared, Broadcom SDK)
GT_BE98_LIBSHARED_REDISTRIBUTE = NO
GT_BE98_LIBSHARED_INSTALL_STAGING = YES

GT_BE98_LIBSHARED_MERLIN_ROOT ?= $(BR2_EXTERNAL_GT_BE98_PATH)/../gt-be98-firmware
GT_BE98_LIBSHARED_SDK = $(GT_BE98_LIBSHARED_MERLIN_ROOT)/vendor/asuswrt-merlin.ng/release/src-rt-5.04behnd.4916

define GT_BE98_LIBSHARED_BUILD_CMDS
	GTBE98_ROOT="$(GT_BE98_LIBSHARED_MERLIN_ROOT)" \
	SDK="$(GT_BE98_LIBSHARED_SDK)" \
	PKG_SRC="$(GT_BE98_LIBSHARED_PKGDIR)/src" \
	OUTDIR="$(@D)" \
		$(SHELL) $(GT_BE98_LIBSHARED_PKGDIR)/src/build-libshared.sh
endef

# Staging so rc / hostapd (and any from-source consumer) can link -lshared.
define GT_BE98_LIBSHARED_INSTALL_STAGING_CMDS
	$(INSTALL) -D -m 0755 $(@D)/libshared.so $(STAGING_DIR)/usr/lib/libshared.so
endef

define GT_BE98_LIBSHARED_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/libshared.so $(TARGET_DIR)/usr/lib/libshared.so
endef

$(eval $(generic-package))
