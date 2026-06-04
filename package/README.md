# GT-BE98 Buildroot packages

Recipes (Config.in + .mk + .hash) for GT-BE98-specific packages. **Recipes only —
no sources/blobs here.** Source tarballs and firmware blobs live in
`gt-be98-packages` and are fetched by URL (GitHub Release assets) at build time.

## Adding a package

Create `package/<name>/`:

```
package/gt-be98-dhd-firmware/
├── Config.in
├── gt-be98-dhd-firmware.mk
└── gt-be98-dhd-firmware.hash
```

Then add to the top-level `Config.in`:
```
source "$BR2_EXTERNAL_GT_BE98_PATH/package/gt-be98-dhd-firmware/Config.in"
```
(`external.mk` auto-includes every `package/*/*.mk`.)

### Config.in
```
config BR2_PACKAGE_GT_BE98_DHD_FIRMWARE
	bool "gt-be98-dhd-firmware"
	help
	  Broadcom dhd wireless firmware blobs (rtecdc.bin) for the
	  GT-BE98 radios (6717a0 + 6726b0).
```

### gt-be98-dhd-firmware.mk
```
GT_BE98_DHD_FIRMWARE_VERSION = 1.0
# Hosted as a gt-be98-packages Release asset (fetch by URL, no LFS):
GT_BE98_DHD_FIRMWARE_SITE = https://github.com/nebuloss/gt-be98-packages/releases/download/dhd-firmware-$(GT_BE98_DHD_FIRMWARE_VERSION)
GT_BE98_DHD_FIRMWARE_SOURCE = gt-be98-dhd-firmware-$(GT_BE98_DHD_FIRMWARE_VERSION).tar.gz
GT_BE98_DHD_FIRMWARE_LICENSE = PROPRIETARY
GT_BE98_DHD_FIRMWARE_REDISTRIBUTE = NO

define GT_BE98_DHD_FIRMWARE_INSTALL_TARGET_CMDS
	$(INSTALL) -d $(TARGET_DIR)/rom/etc/wlan
	cp -a $(@D)/* $(TARGET_DIR)/rom/etc/wlan/
endef

$(eval $(generic-package))
```

### gt-be98-dhd-firmware.hash
```
# sha256 from gt-be98-packages MANIFEST
sha256  <sha>  gt-be98-dhd-firmware-1.0.tar.gz
```

## Candidate first packages (proprietary, must self-host)

- `gt-be98-dhd-firmware` — rtecdc.bin (6717a0/6726b0)
- `gt-be98-wl` / `gt-be98-dhd` — wireless driver blobs
- `gt-be98-httpd` — asus web UI + httpd (has prebuilt `web-broadcom_private.o`)
- `gt-be98-nvram` — libnvram + nvram defaults

See `gt-be98-firmware/tools/verify-artifact.sh` for the full required-component list.
