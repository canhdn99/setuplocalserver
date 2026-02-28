#!/usr/bin/env bash
set -euo pipefail

# =========================
# usbeth.sh - Auto setup USB Ethernet on Ubuntu Server
# - Stable interface name: usbeth0 (udev by MAC)
# - Configure DHCP via systemd-networkd
# - Prefer usbeth0 over WiFi using RouteMetric
# - Disable cloud-init network config to avoid reset on reboot
# =========================

# EDIT THIS: MAC address of your USB Ethernet adapter (from: ip link show <iface>)
USB_MAC="00:0e:c6:77:ee:a2"

# Optional tuning
USB_NAME="usbeth0"
USB_METRIC="10"
WIFI_GLOB="wlp*"
WIFI_METRIC="600"

UDEV_RULE="/etc/udev/rules.d/10-usb-ethernet-name.rules"
NET_USB="/etc/systemd/network/10-usbeth0.network"
NET_WIFI="/etc/systemd/network/20-wifi.network"
CLOUD_DISABLE="/etc/cloud/cloud.cfg.d/99-disable-network-config.cfg"
NETPLAN_CLOUD="/etc/netplan/50-cloud-init.yaml"

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Please run as root: sudo $0"
    exit 1
  fi
}

backup_if_exists() {
  local f="$1"
  if [[ -e "$f" ]]; then
    local ts
    ts="$(date +%Y%m%d_%H%M%S)"
    cp -a "$f" "${f}.bak_${ts}"
    echo "Backup created: ${f}.bak_${ts}"
  fi
}

write_file() {
  local path="$1"
  local content="$2"
  backup_if_exists "$path"
  printf "%s\n" "$content" > "$path"
  echo "Wrote: $path"
}

main() {
  need_root

  if [[ "$USB_MAC" == "00:00:00:00:00:00" || "$USB_MAC" == "" ]]; then
    echo "ERROR: Please set USB_MAC at top of script."
    exit 1
  fi

  echo "Step 1 - Create udev rule to rename interface by MAC"
  write_file "$UDEV_RULE" \
"SUBSYSTEM==\"net\", ACTION==\"add\", ATTR{address}==\"${USB_MAC}\", NAME=\"${USB_NAME}\""

  echo "Step 2 - Enable systemd-networkd"
  systemctl enable systemd-networkd >/dev/null
  systemctl enable systemd-networkd.socket >/dev/null || true

  mkdir -p /etc/systemd/network

  echo "Step 3 - Configure DHCP for ${USB_NAME} with low metric (preferred)"
  write_file "$NET_USB" \
"[Match]
Name=${USB_NAME}

[Link]
RequiredForOnline=no

[Network]
DHCP=yes

[DHCP]
RouteMetric=${USB_METRIC}
"

  echo "Step 4 - Configure WiFi metric higher (optional, safe even if no WiFi)"
  write_file "$NET_WIFI" \
"[Match]
Name=${WIFI_GLOB}

[Network]
DHCP=yes

[DHCP]
RouteMetric=${WIFI_METRIC}
"

  echo "Step 5 - Disable cloud-init network to prevent overwriting config"
  mkdir -p /etc/cloud/cloud.cfg.d
  write_file "$CLOUD_DISABLE" \
"network:
  config: disabled
"

  echo "Step 6 - Remove cloud-init netplan file if present (optional)"
  if [[ -e "$NETPLAN_CLOUD" ]]; then
    backup_if_exists "$NETPLAN_CLOUD"
    rm -f "$NETPLAN_CLOUD"
    echo "Removed: $NETPLAN_CLOUD"
  else
    echo "Not found: $NETPLAN_CLOUD (skip)"
  fi

  echo "Step 7 - Reload udev and restart networkd"
  udevadm control --reload
  systemctl restart systemd-udevd
  systemctl restart systemd-networkd

  echo
  echo "Done."
  echo "Next: reboot to apply rename, then check:"
  echo "  ip link show ${USB_NAME}"
  echo "  networkctl status ${USB_NAME}"
  echo "  ip route | head"
  echo
  echo "If ${USB_NAME} does not appear after reboot, verify USB_MAC is correct."
}

main "$@"

