################################################################################
#
# gt-be98-webui
#
################################################################################

# Hook for the webui-go port (separate repository and build): installs a
# prebuilt delivery from a local directory; nothing is downloaded or built.
# www-portal/, www-captive/ and scripts/ are never installed.
GT_BE98_WEBUI_SOURCE =
GT_BE98_WEBUI_LICENSE = see gt-be98-webui-go
GT_BE98_WEBUI_DIR_SRC = $(call qstrip,$(BR2_PACKAGE_GT_BE98_WEBUI_DIR))

ifneq ($(GT_BE98_WEBUI_DIR_SRC),)
define GT_BE98_WEBUI_INSTALL_DELIVERY
	set -e; S=$(GT_BE98_WEBUI_DIR_SRC); \
	for f in webui www/ openrc/webui openrc/webui.confd platform.conf.example; do \
		test -e $$S/$$f || { echo "gt-be98-webui: $$S/$$f missing"; exit 1; }; done; \
	if [ -f $$S/webui.sha256 ]; then \
		(cd $$S && sha256sum -c --quiet webui.sha256) || \
		{ echo "gt-be98-webui: webui sha256 mismatch"; exit 1; }; fi; \
	$(INSTALL) -D -m 0755 $$S/webui $(TARGET_DIR)/usr/sbin/webui; \
	rm -rf $(TARGET_DIR)/usr/share/webui/www; \
	mkdir -p $(TARGET_DIR)/usr/share/webui/www; \
	cp -R $$S/www/. $(TARGET_DIR)/usr/share/webui/www/; \
	find $(TARGET_DIR)/usr/share/webui/www -type d -exec chmod 0755 {} +; \
	find $(TARGET_DIR)/usr/share/webui/www -type f -exec chmod 0644 {} +; \
	$(INSTALL) -D -m 0755 $$S/openrc/webui $(TARGET_DIR)/etc/init.d/webui; \
	$(INSTALL) -D -m 0644 $$S/openrc/webui.confd $(TARGET_DIR)/etc/conf.d/webui; \
	test -f $(TARGET_DIR)/etc/webui/platform.conf || \
		$(INSTALL) -D -m 0600 $$S/platform.conf.example $(TARGET_DIR)/etc/webui/platform.conf
endef
else
define GT_BE98_WEBUI_INSTALL_DELIVERY
	$(INSTALL) -D -m 0755 $(GT_BE98_WEBUI_PKGDIR)/webui.init $(TARGET_DIR)/etc/init.d/webui
	test -f $(TARGET_DIR)/etc/conf.d/webui || \
		$(INSTALL) -D -m 0644 $(GT_BE98_WEBUI_PKGDIR)/webui.confd $(TARGET_DIR)/etc/conf.d/webui
endef
endif

define GT_BE98_WEBUI_INSTALL_TARGET_CMDS
	mkdir -p $(TARGET_DIR)/etc/webui
	$(GT_BE98_WEBUI_INSTALL_DELIVERY)
	chmod 0700 $(TARGET_DIR)/etc/webui
	# never enabled by default (the orchestrator enables it for tests)
	rm -f $(TARGET_DIR)/etc/runlevels/*/webui
endef

$(eval $(generic-package))
