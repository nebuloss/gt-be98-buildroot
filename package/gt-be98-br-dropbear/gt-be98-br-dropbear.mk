################################################################################
#
# gt-be98-br-dropbear
#
# Static dropbearmulti 2025.89 for the /usr/br island (M5 candidate 1,
# br-0041), rebuilt FROM SOURCE (br-0044). Components: dropbear server,
# dbclient/ssh, dropbearkey/ssh-keygen, scp - same set as the committed
# binary; no dropbearconvert. zlib off (compression "none" only), bundled
# libtom (no external libtomcrypt in the static glibc sysroot). Server
# password auth compiled out (key-only, the br-0041 design) - the static
# build has no crypt() anyway, the explicit define makes it a guarantee.
# Because crypt() is thus unreferenced we force configure's AC_CHECK_LIB cache
# var ac_cv_lib_crypt_crypt=no so @CRYPTLIB@ stays empty: the Buildroot-staged
# external sysroot ships only libcrypt.so (no .a), so the otherwise-appended
# -lcrypt would break the -static link (the manual br-0041 build linked against
# the firmware sysroot, which has libcrypt.a).
#
# SFTP (br-0048): localoptions.h sets DROPBEAR_SFTPSERVER + repoints
# SFTPSERVER_PATH from the upstream default /usr/libexec/sftp-server to
# /usr/br/libexec/sftp-server (the OpenSSH sftp-server harvested by
# gt-be98-br-openssh). dropbear bundles no sftp-server of its own; with this
# the :2223 server advertises the sftp subsystem, so modern OpenSSH scp/sftp
# (which speak the sftp protocol) work against it.
#
# Used by the S28 br-dropbear rail on port 2223. Harvested into the ASUS
# rootfs at /usr/br/sbin/dropbearmulti by rootfs-transform.sh (no command
# symlinks - the rail invokes "dropbearmulti <cmd>" directly, matching the
# committed br-0043 layout).
#
################################################################################

GT_BE98_BR_DROPBEAR_VERSION = 2025.89
GT_BE98_BR_DROPBEAR_SOURCE = dropbear-$(GT_BE98_BR_DROPBEAR_VERSION).tar.bz2
GT_BE98_BR_DROPBEAR_SITE = https://matt.ucc.asn.au/dropbear/releases
GT_BE98_BR_DROPBEAR_LICENSE = MIT, BSD-2-Clause, Public domain
GT_BE98_BR_DROPBEAR_LICENSE_FILES = LICENSE

GT_BE98_BR_DROPBEAR_PROGRAMS = dropbear dbclient dropbearkey scp

define GT_BE98_BR_DROPBEAR_CONFIGURE_CMDS
	printf '#define DROPBEAR_SVR_PASSWORD_AUTH 0\n' > $(@D)/localoptions.h
	printf '#define DROPBEAR_SFTPSERVER 1\n' >> $(@D)/localoptions.h
	printf '#define SFTPSERVER_PATH "/usr/br/libexec/sftp-server"\n' >> $(@D)/localoptions.h
	cd $(@D) && $(TARGET_CONFIGURE_OPTS) ac_cv_lib_crypt_crypt=no ./configure \
		--host=$(GNU_TARGET_NAME) \
		--prefix=/usr/br \
		--enable-static \
		--disable-zlib \
		--enable-bundled-libtom
endef

define GT_BE98_BR_DROPBEAR_BUILD_CMDS
	$(TARGET_MAKE_ENV) $(MAKE) -C $(@D) MULTI=1 SCPPROGRESS=1 \
		PROGRAMS="$(GT_BE98_BR_DROPBEAR_PROGRAMS)"
	$(TARGET_CROSS)strip $(@D)/dropbearmulti
endef

# no target-install: harvested by board/gt-be98/rootfs-transform.sh

$(eval $(generic-package))
