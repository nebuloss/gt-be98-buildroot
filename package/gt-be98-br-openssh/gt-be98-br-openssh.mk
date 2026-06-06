################################################################################
#
# gt-be98-br-openssh
#
# OpenSSH 10.2p1 for the /usr/br island (M5, br-0046). Provides the
# sftp-server that the from-source dropbear (S28, :2223) execs for the sftp
# subsystem - this is what makes modern OpenSSH `scp`/`sftp` work against the
# device, since dropbear ships NO server-side sftp/scp of its own. The scp/
# sftp/ssh/ssh-keygen clients are harvested too.
#
# LINK STRATEGY (deliberate, see board/gt-be98/rootfs-transform.sh guard):
#   - openssl 3.6.2 is linked STATICALLY from our gt-be98-br-openssl build's
#     staged dev tree ($(GT_BE98_BR_OPENSSL_DIR)/_brdev/usr/br). The device
#     rootfs ships only openssl 1.1 (libcrypto.so.1.1); a dynamic link would
#     be a hard ABI mismatch. Static libcrypto.a pulls dlopen()/pthread, hence
#     LIBS="-ldl -pthread".
#   - glibc + zlib are DYNAMIC against the device's own libs: the ASUS rootfs
#     ships /lib/ld-linux.so.3 + libc/libdl/libcrypt/libresolv/libutil/
#     libpthread/libm and /usr/lib/libz.so.1, so the harvested binaries are
#     ELF interpreter /lib/ld-linux.so.3 with only satisfiable DT_NEEDED. This
#     is NOT fully-static (unlike busybox/dropbear/openssl); rootfs-transform's
#     harvest step has a SEPARATE dynamic-linkage guard for these.
#
# Nothing is installed to Buildroot's (throwaway) TARGET_DIR - the binaries are
# harvested out of $(@D) by rootfs-transform.sh step 2b into /usr/br.
#
################################################################################

GT_BE98_BR_OPENSSH_VERSION = 10.2p1
GT_BE98_BR_OPENSSH_SOURCE = openssh-$(GT_BE98_BR_OPENSSH_VERSION).tar.gz
GT_BE98_BR_OPENSSH_SITE = http://ftp.openbsd.org/pub/OpenBSD/OpenSSH/portable
GT_BE98_BR_OPENSSH_LICENSE = BSD-3-Clause, BSD-2-Clause, Public Domain
GT_BE98_BR_OPENSSH_LICENSE_FILES = LICENCE

# Build-time deps: our static openssl 3.6.2 (crypto backend, staged dev tree)
# and zlib (staging libz, dynamically linked - present on the device).
GT_BE98_BR_OPENSSH_DEPENDENCIES = gt-be98-br-openssl zlib

# Crypto backend = the /usr/br openssl 3.6.2 staged dev tree (static libs only).
GT_BE98_BR_OPENSSH_SSL_DIR = $(GT_BE98_BR_OPENSSL_DIR)/_brdev/usr/br

GT_BE98_BR_OPENSSH_CONF_ENV = \
	LD="$(TARGET_CC)" \
	LDFLAGS="$(TARGET_CFLAGS)" \
	LIBS="-ldl -pthread"

GT_BE98_BR_OPENSSH_CONF_OPTS = \
	--prefix=/usr/br \
	--sysconfdir=/usr/br/etc/ssh \
	--with-ssl-dir=$(GT_BE98_BR_OPENSSH_SSL_DIR) \
	--without-pam \
	--without-selinux \
	--without-sandbox \
	--without-audit \
	--without-ssl-engine \
	--disable-lastlog \
	--disable-utmp \
	--disable-utmpx \
	--disable-wtmp \
	--disable-wtmpx \
	--disable-strip

# We harvest from $(@D), never install to TARGET_DIR (the /usr/br island model).
GT_BE98_BR_OPENSSH_INSTALL_TARGET = NO
GT_BE98_BR_OPENSSH_INSTALL_STAGING = NO

# Strip the binaries we will harvest (configure ran with --disable-strip so the
# install rule -- which we skip anyway -- would not strip them).
define GT_BE98_BR_OPENSSH_STRIP
	$(TARGET_CROSS)strip $(@D)/sftp-server $(@D)/scp $(@D)/sftp \
		$(@D)/ssh $(@D)/ssh-keygen
endef
GT_BE98_BR_OPENSSH_POST_BUILD_HOOKS += GT_BE98_BR_OPENSSH_STRIP

$(eval $(autotools-package))
