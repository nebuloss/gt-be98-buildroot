################################################################################
#
# gt-be98-webui
#
################################################################################

# Hook for the webui-go port (separate repository and build). Installs a
# prebuilt binary from a local path; nothing is downloaded or compiled here.
GT_BE98_WEBUI_SOURCE =
GT_BE98_WEBUI_LICENSE = see gt-be98-webui-go
GT_BE98_WEBUI_BINARY = $(call qstrip,$(BR2_PACKAGE_GT_BE98_WEBUI_BINARY))
GT_BE98_WEBUI_EXTRA_DIR = $(call qstrip,$(BR2_PACKAGE_GT_BE98_WEBUI_EXTRA_DIR))

define GT_BE98_WEBUI_INSTALL_TARGET_CMDS
	mkdir -p $(TARGET_DIR)/etc/webui
	$(INSTALL) -D -m 0755 $(GT_BE98_WEBUI_PKGDIR)/webui.init \
		$(TARGET_DIR)/etc/init.d/webui
	test -f $(TARGET_DIR)/etc/conf.d/webui || \
		$(INSTALL) -D -m 0644 $(GT_BE98_WEBUI_PKGDIR)/webui.confd \
			$(TARGET_DIR)/etc/conf.d/webui
	$(if $(GT_BE98_WEBUI_BINARY), \
		test -f $(GT_BE98_WEBUI_BINARY) || { echo "missing $(GT_BE98_WEBUI_BINARY)"; exit 1; }; \
		$(INSTALL) -D -m 0755 $(GT_BE98_WEBUI_BINARY) $(TARGET_DIR)/usr/sbin/webui)
	$(if $(GT_BE98_WEBUI_EXTRA_DIR), \
		test -d $(GT_BE98_WEBUI_EXTRA_DIR) || { echo "missing $(GT_BE98_WEBUI_EXTRA_DIR)"; exit 1; }; \
		cp -a $(GT_BE98_WEBUI_EXTRA_DIR)/. $(TARGET_DIR)/)
endef

$(eval $(generic-package))
