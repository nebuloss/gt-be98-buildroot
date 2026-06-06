################################################################################
#
# gt-be98-br-openssl
#
# Static openssl 3.6.2 CLI for the /usr/br island (M5 candidate 3, br-0043),
# rebuilt FROM SOURCE (br-0044). Configure mirrors the committed binary
# exactly (verified via `strings`/version -a fingerprints):
#   linux-armv4, prefix /usr/br (=> ENGINESDIR /usr/br/lib/engines-3,
#   MODULESDIR /usr/br/lib/ossl-modules), OPENSSLDIR /usr/br/etc/ssl
#   (the first br-0043 build's default /usr/local/ssl broke `req` on-device),
#   no-shared + -static => fully static app, default -Wall -O3 flags.
#
# Only apps/openssl is consumed: harvested into the ASUS rootfs at
# /usr/br/bin/openssl by rootfs-transform.sh. The stock openssl.cnf + ssl
# dirs stay in the git overlay (config/rails only - never binaries).
#
################################################################################

GT_BE98_BR_OPENSSL_VERSION = 3.6.2
GT_BE98_BR_OPENSSL_SOURCE = openssl-$(GT_BE98_BR_OPENSSL_VERSION).tar.gz
GT_BE98_BR_OPENSSL_SITE = https://github.com/openssl/openssl/releases/download/openssl-$(GT_BE98_BR_OPENSSL_VERSION)
GT_BE98_BR_OPENSSL_LICENSE = Apache-2.0
GT_BE98_BR_OPENSSL_LICENSE_FILES = LICENSE.txt

define GT_BE98_BR_OPENSSL_CONFIGURE_CMDS
	cd $(@D) && $(TARGET_MAKE_ENV) CROSS_COMPILE="$(GNU_TARGET_NAME)-" \
		./Configure linux-armv4 \
		--prefix=/usr/br \
		--openssldir=/usr/br/etc/ssl \
		no-shared \
		-static
endef

define GT_BE98_BR_OPENSSL_BUILD_CMDS
	$(TARGET_MAKE_ENV) $(MAKE) -C $(@D) build_sw
	$(TARGET_CROSS)strip $(@D)/apps/openssl
endef

# no target-install: harvested by board/gt-be98/rootfs-transform.sh

$(eval $(generic-package))
