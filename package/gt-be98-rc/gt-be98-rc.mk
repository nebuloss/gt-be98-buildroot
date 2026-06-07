################################################################################
#
# gt-be98-rc  (rc, the asuswrt-merlin init/service engine, from source)
#
# Links rc FROM SOURCE via the merlin SDK build-glue (same proven env as
# gt-be98-libshared) plus ASUSWRT_BRCM_SDK_VERSION=WIFI7_SDK_20231126, which
# selects the GT-BE98 `_be` prebuild .o variant the device ships. rc's 108 open
# .c compile cleanly; the remaining vendor objects come from prebuild/GT-BE98/.
#
# LINK closure (what `rc:` pulls in via LDFLAGS2):
#   from-source : libshared (gt-be98-libshared, built in-place at
#                 router/shared, byte-identical to device) ; libnvram soname
#                 satisfied at runtime by the clean-room gt-be98-nvram
#                 (ABI-compatible) — at link time -lnvram resolves from the SDK
#                 in-tree router-sysdep/nvram build (same ABI/soname).
#   pinned graft: the irreducible Broadcom core already built in the SDK tree
#                 (router-sysdep/{ethctl_lib,gen_util,sys_util,wlcsm,
#                 bcm_flashutil,bcm_util,bcm_boardctl}, router/{libbcm,wlc_nt,
#                 libdisk,json-c,sqlite,openssl,libconn_diag}) + libwpa_client
#                 staged into a -L graftlibs dir (its in-Makefile -L path is
#                 empty for this config).
#
# Verified: ELF32 ARM EABI5, soft-float; DT_NEEDED 36-lib closure all resolve;
# notify_rc is U (resolved from the from-source libshared override); rc verbs
# present (178 start_* / 168 stop_* / 13 restart_* / sync_boot_state / main).
# Byte-identity to the device rc is NOT expected (different lib provenance);
# ABI/closure correctness is the bar — met.
#
# Depends on gt-be98-libshared (populates router/shared/libshared.so that rc
# links -lshared against) and gt-be98-nvram. Requires the firmware tree
# (override with GT_BE98_RC_MERLIN_ROOT). Not wired into gt-be98_full_defconfig.
#
################################################################################

GT_BE98_RC_VERSION = 1.0
GT_BE98_RC_SITE = $(GT_BE98_RC_PKGDIR)/src
GT_BE98_RC_SITE_METHOD = local
GT_BE98_RC_LICENSE = PROPRIETARY (asuswrt-merlin rc, Broadcom SDK)
GT_BE98_RC_REDISTRIBUTE = NO
GT_BE98_RC_DEPENDENCIES = gt-be98-libshared gt-be98-nvram

GT_BE98_RC_MERLIN_ROOT ?= $(BR2_EXTERNAL_GT_BE98_PATH)/../gt-be98-firmware
GT_BE98_RC_SDK = $(GT_BE98_RC_MERLIN_ROOT)/vendor/asuswrt-merlin.ng/release/src-rt-5.04behnd.4916

define GT_BE98_RC_BUILD_CMDS
	GTBE98_ROOT="$(GT_BE98_RC_MERLIN_ROOT)" \
	SDK="$(GT_BE98_RC_SDK)" \
	PKG_SRC="$(GT_BE98_RC_PKGDIR)/src" \
	OUTDIR="$(@D)" \
		$(SHELL) $(GT_BE98_RC_PKGDIR)/src/build-rc.sh
endef

define GT_BE98_RC_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0500 $(@D)/rc $(TARGET_DIR)/sbin/rc
endef

$(eval $(generic-package))
