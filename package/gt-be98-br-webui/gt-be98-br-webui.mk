################################################################################
#
# gt-be98-br-webui
#
# Static, pure-Go webui-go management backend for the /usr/br island (M5
# candidate 4, br-0047). This is the open web UI that replaces the ASUS GUI;
# its control path is audited correct vs the verified netctl primitives
# (docs/device/webui-go-audit.md). Cross-compiled with the external host Go
# toolchain to a FULLY STATIC ARM EABI binary:
#   CGO_ENABLED=0 GOOS=linux GOARCH=arm GOARM=7
# modernc.org/sqlite is a pure-Go SQLite (no CGO, no libc), so the result has
# no PT_INTERP and no DT_NEEDED - it drops into the static /usr/br island with
# no shared-lib dependency (verified by the rootfs-transform static guard).
#
# SOURCE: the sibling gt-be98-webui-go git checkout (SITE_METHOD=local). It is
# NOT yet published as a gt-be98-packages Release asset; when it is, switch to
# the URL+hash convention (package/README.md) - SITE/SOURCE/.hash like the
# br-openssl recipe. Override the checkout location with GT_BE98_BR_WEBUI_REPO.
#
# MODULES: built offline from the host module cache ($(HOME)/go/pkg/mod) with
# GOPROXY=off; the go.sum in the checkout pins every dependency. The host Go
# is $(HOME)/go-sdk/go/bin/go (as deploy/push.sh uses), falling back to `go`
# on PATH; override with GT_BE98_BR_WEBUI_GO. Buildroot host-go is NOT used
# (BR2_PACKAGE_HOST_GO is off and webui-go needs Go >= 1.26).
#
# Only the produced binary is consumed: harvested into the ASUS rootfs at
# /usr/br/sbin/webui by rootfs-transform.sh and launched by the S29 br-webui
# rail (parallel listener on a test port; ASUS httpd untouched). The static
# UI assets stay on /jffs/webui/www (deployed by deploy/push.sh) - the git
# overlay carries config/rails only, never binaries.
#
################################################################################

GT_BE98_BR_WEBUI_REPO ?= $(HOME)/be98/gt-be98-webui-go
GT_BE98_BR_WEBUI_VERSION = $(shell git -C $(GT_BE98_BR_WEBUI_REPO) describe --always --dirty 2>/dev/null || echo dev)
GT_BE98_BR_WEBUI_SITE = $(GT_BE98_BR_WEBUI_REPO)
GT_BE98_BR_WEBUI_SITE_METHOD = local
GT_BE98_BR_WEBUI_LICENSE = proprietary
GT_BE98_BR_WEBUI_REDISTRIBUTE = NO

# External host Go toolchain (Buildroot host-go is not built; webui-go needs
# Go >= 1.26). Prefer the pinned SDK that deploy/push.sh uses, else PATH `go`.
GT_BE98_BR_WEBUI_GO ?= $(or $(wildcard $(HOME)/go-sdk/go/bin/go),go)

define GT_BE98_BR_WEBUI_BUILD_CMDS
	cd $(@D) && \
		CGO_ENABLED=0 GOOS=linux GOARCH=arm GOARM=7 \
		GOPROXY=off GOFLAGS=-mod=mod \
		GOMODCACHE=$(HOME)/go/pkg/mod \
		GOCACHE=$(@D)/.gocache \
		$(GT_BE98_BR_WEBUI_GO) build -trimpath \
			-ldflags "-s -w -X main.version=$(GT_BE98_BR_WEBUI_VERSION)" \
			-o $(@D)/webui .
endef

# no target-install: harvested by board/gt-be98/rootfs-transform.sh
# (find ... -name webui -path '*gt-be98-br-webui*'), with the same
# static-linkage guard as busybox/dropbear/openssl.

$(eval $(generic-package))
