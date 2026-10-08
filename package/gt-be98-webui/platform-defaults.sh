#!/bin/sh
# SPDX-License-Identifier: GPL-2.0
# GT-BE98 dev OS defaults for /etc/webui/platform.conf (on top of the
# delivered example): WAN_IF=rnr0 (the LAN port, a plain DHCP client, never
# bridged), MGMT_IF=eth0 (the USB lifeline), DNSMASQ_DNS=0, and no
# ALLOW_MULTI_PORT_BRIDGE (multi-port bridging stays off).
set -eu
f=${1:?platform.conf}
sed -i -E '/^(WAN_IF|MGMT_IF|DNSMASQ_DNS|ALLOW_MULTI_PORT_BRIDGE)=/d' "$f"
cat >> "$f" <<'CONF'

# --- GT-BE98 mainline dev OS defaults (gt-be98-webui package) ---------------
WAN_IF=rnr0
MGMT_IF=eth0
DNSMASQ_DNS=0
CONF
