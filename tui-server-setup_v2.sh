#!/usr/bin/env bash
# combined-server-24x7-usbeth.sh
# Run:
#   sudo bash combined-server-24x7-usbeth.sh
# With USB Ethernet auto-setup:
#   sudo bash combined-server-24x7-usbeth.sh --enable-usbeth
# Optional:
#   sudo bash combined-server-24x7-usbeth.sh --enable-usbeth --usb-iface enx1234abcd...
#   sudo bash combined-server-24x7-usbeth.sh --enable-usbeth --usb-name usbeth0 --usb-metric 10 --wifi-glob "wlp*" --wifi-metric 600

set -Eeuo pipefail

# Fix terminal mode
if [[ -t 0 ]]; then
  export TERM="${TERM:-xterm-256color}"
  stty sane 2>/dev/null || true
fi

# =========================
# Logging (24x7 script style)
# =========================
LOG_DIR="/var/log/24x7-setup"
LOG_FILE="$LOG_DIR/setup-$(date +%F-%H%M%S).log"

mkdir -p "$LOG_DIR"
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

if [[ -t 1 ]]; then
  RED="$(printf '\033[31m')"
  GREEN="$(printf '\033[32m')"
  YELLOW="$(printf '\033[33m')"
  BLUE="$(printf '\033[34m')"
  RESET="$(printf '\033[0m')"
else
  RED=""; GREEN=""; YELLOW=""; BLUE=""; RESET=""
fi

STEP=0

on_err() {
  local exit_code=$?
  echo "${RED}[ERROR]${RESET} Script failed at step ${STEP}. Exit code: ${exit_code}"
  echo "${RED}[ERROR]${RESET} Check log: ${LOG_FILE}"
  echo "${RED}[ERROR]${RESET} Last 80 lines:"
  tail -n 80 "$LOG_FILE" || true
  exit "$exit_code"
}
trap on_err ERR

info() { echo "${BLUE}[INFO]${RESET} $*"; }
warn() { echo "${YELLOW}[WARN]${RESET} $*"; }
ok()   { echo "${GREEN}[OK]${RESET} $*"; }

begin_step() {
  STEP=$((STEP+1))
  echo
  echo "============================================================"
  echo "[STEP ${STEP}] $*"
  echo "Timestamp: $(date -Is)"
  echo "============================================================"
}

run() {
  info "Running: $*"
  "$@"
  ok "Done: $*"
}

# =========================
# Args
# =========================
ENABLE_USBETH=0
USB_IFACE=""
USB_MAC=""
USB_NAME="usbeth0"
USB_METRIC="10"
WIFI_GLOB="wlp*"
WIFI_METRIC="600"

usage() {
  cat <<'EOF'
Usage:
  sudo bash combined-server-24x7-usbeth.sh [options]

Options:
  --enable-usbeth            Enable USB Ethernet setup (auto-detect USB NIC)
  --usb-iface <iface>        Force choose a specific interface (ex: enx..., enp...)
  --usb-name <name>          Name to assign via udev (default: usbeth0)
  --usb-metric <num>         RouteMetric for usbeth (default: 10)
  --wifi-glob <glob>         WiFi match glob (default: wlp*)
  --wifi-metric <num>        RouteMetric for WiFi (default: 600)
  -h, --help                 Show help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --enable-usbeth) ENABLE_USBETH=1; shift ;;
    --usb-iface) USB_IFACE="${2:-}"; shift 2 ;;
    --usb-name) USB_NAME="${2:-}"; shift 2 ;;
    --usb-metric) USB_METRIC="${2:-}"; shift 2 ;;
    --wifi-glob) WIFI_GLOB="${2:-}"; shift 2 ;;
    --wifi-metric) WIFI_METRIC="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1"; usage; exit 1 ;;
  esac
done

# =========================
# Helpers
# =========================
require_root() {
  begin_step "Check root privileges"
  if [[ "${EUID}" -ne 0 ]]; then
    echo "${RED}[ERROR]${RESET} Please run as root: sudo bash $0"
    exit 1
  fi
  ok "Running as root."
  info "Log file: $LOG_FILE"
}

detect_user() {
  begin_step "Detect primary non-root user"
  if [[ -n "${SUDO_USER-}" && "${SUDO_USER}" != "root" ]]; then
    PRIMARY_USER="${SUDO_USER}"
  else
    PRIMARY_USER="$(awk -F: '$3>=1000 && $1!="nobody" {print $1; exit}' /etc/passwd || true)"
  fi

  if [[ -z "${PRIMARY_USER}" ]]; then
    warn "Could not detect a non-root user. Some user-specific steps will be skipped."
  else
    ok "Primary user: ${PRIMARY_USER}"
    PRIMARY_HOME="$(eval echo "~${PRIMARY_USER}")"
    info "Primary home: ${PRIMARY_HOME}"
  fi
}

backup_if_exists() {
  local f="$1"
  if [[ -e "$f" ]]; then
    local ts
    ts="$(date +%Y%m%d_%H%M%S)"
    cp -a "$f" "${f}.bak_${ts}"
    info "Backup created: ${f}.bak_${ts}"
  fi
}

write_file() {
  local path="$1"
  local content="$2"
  backup_if_exists "$path"
  printf "%s\n" "$content" > "$path"
  info "Wrote: $path"
}

# =========================
# Base server setup (24x7)
# =========================
apt_update_upgrade() {
  begin_step "Update and upgrade packages"
  run apt-get update
  run apt-get -y upgrade
  run apt-get -y autoremove
}

set_timezone() {
  begin_step "Set timezone to Asia/Bangkok"
  if timedatectl list-timezones | grep -qx "Asia/Bangkok"; then
    run timedatectl set-timezone "Asia/Bangkok"
    run timedatectl
  else
    warn "Timezone Asia/Bangkok not found. Skipping."
  fi
}

install_basics() {
  begin_step "Install useful packages (ssh, ufw, curl, nc, sensors, tlp)"
  run apt-get install -y \
    openssh-server ufw curl wget nano \
    net-tools iproute2 \
    netcat-openbsd \
    lm-sensors tlp
  run apt-get install -y smartmontools || true
  ok "Installed packages."
}

configure_ssh() {
  begin_step "Enable and harden SSH (safe defaults)"
  run systemctl enable ssh
  run systemctl start ssh

  info "Backing up sshd_config"
  local cfg="/etc/ssh/sshd_config"
  if [[ -f "$cfg" ]]; then
    run cp -a "$cfg" "${cfg}.bak.$(date +%F-%H%M%S)"
  fi

  if ! grep -qE '^[[:space:]]*PermitRootLogin[[:space:]]+' "$cfg"; then
    echo "PermitRootLogin no" >> "$cfg"
  else
    run sed -i 's/^[[:space:]]*#\{0,1\}[[:space:]]*PermitRootLogin[[:space:]].*/PermitRootLogin no/' "$cfg"
  fi

  if ! grep -qE '^[[:space:]]*PasswordAuthentication[[:space:]]+' "$cfg"; then
    echo "PasswordAuthentication yes" >> "$cfg"
  else
    run sed -i 's/^[[:space:]]*#\{0,1\}[[:space:]]*PasswordAuthentication[[:space:]].*/PasswordAuthentication yes/' "$cfg"
  fi

  if ! grep -qE '^[[:space:]]*PubkeyAuthentication[[:space:]]+' "$cfg"; then
    echo "PubkeyAuthentication yes" >> "$cfg"
  else
    run sed -i 's/^[[:space:]]*#\{0,1\}[[:space:]]*PubkeyAuthentication[[:space:]].*/PubkeyAuthentication yes/' "$cfg"
  fi

  if ! grep -qE '^[[:space:]]*UsePAM[[:space:]]+' "$cfg"; then
    echo "UsePAM yes" >> "$cfg"
  else
    run sed -i 's/^[[:space:]]*#\{0,1\}[[:space:]]*UsePAM[[:space:]].*/UsePAM yes/' "$cfg"
  fi

  info "Validate SSH config"
  run sshd -t
  run systemctl restart ssh
  run systemctl --no-pager -l status ssh
  ok "SSH configured."
}

configure_firewall() {
  begin_step "Configure UFW firewall (allow SSH, enable firewall)"
  run ufw allow OpenSSH || true
  run ufw allow 22/tcp || true
  run ufw default deny incoming
  run ufw default allow outgoing
  run ufw --force enable
  run ufw status verbose
  ok "Firewall configured."
}

disable_sleep_suspend() {
  begin_step "Disable sleep, suspend, hibernate targets"
  run systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
  ok "Sleep targets masked."
}

ignore_lid_close() {
  begin_step "Configure lid close action to ignore"
  local cfg="/etc/systemd/logind.conf"
  run cp -a "$cfg" "${cfg}.bak.$(date +%F-%H%M%S)" || true

  if ! grep -qE '^\[Login\]' "$cfg"; then
    echo "[Login]" >> "$cfg"
  fi

  if grep -qE '^[[:space:]]*HandleLidSwitch=' "$cfg"; then
    run sed -i 's/^[[:space:]]*HandleLidSwitch=.*/HandleLidSwitch=ignore/' "$cfg"
  else
    echo "HandleLidSwitch=ignore" >> "$cfg"
  fi

  if grep -qE '^[[:space:]]*HandleLidSwitchDocked=' "$cfg"; then
    run sed -i 's/^[[:space:]]*HandleLidSwitchDocked=.*/HandleLidSwitchDocked=ignore/' "$cfg"
  else
    echo "HandleLidSwitchDocked=ignore" >> "$cfg"
  fi

  run systemctl restart systemd-logind
  run systemctl --no-pager -l status systemd-logind
  ok "Lid close behavior configured."
}

enable_tlp_sensors() {
  begin_step "Enable TLP and configure sensors"
  run systemctl enable tlp
  run systemctl start tlp
  run systemctl --no-pager -l status tlp
  run sensors-detect --auto || true
  sensors || true
  ok "TLP and sensors ready."
}

set_static_ip_hint() {
  begin_step "Show current IP info"
  ip -br a || true
  echo
  ip route | sed -n '1,8p' || true
  echo
  curl -s ifconfig.me || true
  echo
  ok "IP info printed."
}

# =========================
# USB Ethernet auto detect + setup
# =========================
is_skip_iface() {
  local n="$1"
  [[ "$n" == "lo" ]] && return 0
  [[ "$n" == docker* ]] && return 0
  [[ "$n" == br-* ]] && return 0
  [[ "$n" == veth* ]] && return 0
  [[ "$n" == virbr* ]] && return 0
  [[ "$n" == wl* ]] && return 0
  return 1
}

udev_props() {
  local n="$1"
  udevadm info -q property -p "/sys/class/net/${n}" 2>/dev/null || true
}

is_usb_nic() {
  local n="$1"
  local props
  props="$(udev_props "$n")"
  echo "$props" | grep -qx 'ID_BUS=usb' && return 0
  echo "$props" | grep -q '^ID_USB_DRIVER=' && return 0

  # Fallback: check sysfs path includes "usb"
  local p
  p="$(readlink -f "/sys/class/net/${n}/device" 2>/dev/null || true)"
  [[ "$p" == *"/usb"* ]] && return 0

  return 1
}

pick_usb_iface() {
  local picked=""
  for d in /sys/class/net/*; do
    local n
    n="$(basename "$d")"
    if is_skip_iface "$n"; then
      continue
    fi
    if is_usb_nic "$n"; then
      picked="$n"
      break
    fi
  done
  echo "$picked"
}

get_mac_of_iface() {
  local n="$1"
  cat "/sys/class/net/${n}/address" 2>/dev/null || true
}

setup_usbeth() {
  begin_step "USB Ethernet setup (auto detect MAC + udev rename + systemd-networkd DHCP + metrics)"

  if [[ "$ENABLE_USBETH" -ne 1 ]]; then
    info "USB Ethernet setup not enabled, skipping."
    return 0
  fi

  if [[ -z "$USB_IFACE" ]]; then
    USB_IFACE="$(pick_usb_iface)"
  fi

  if [[ -z "$USB_IFACE" ]]; then
    echo "${RED}[ERROR]${RESET} Cannot find any USB Ethernet interface."
    echo "${YELLOW}[WARN]${RESET} Plug in USB Ethernet, then run again, or specify: --usb-iface <iface>"
    ip -br link || true
    exit 1
  fi

  USB_MAC="$(get_mac_of_iface "$USB_IFACE")"
  if [[ -z "$USB_MAC" || "$USB_MAC" == "00:00:00:00:00:00" ]]; then
    echo "${RED}[ERROR]${RESET} Cannot read MAC from interface: $USB_IFACE"
    exit 1
  fi

  info "Detected USB NIC: ${USB_IFACE}"
  info "Detected MAC: ${USB_MAC}"
  info "Will rename to: ${USB_NAME}"

  local UDEV_RULE="/etc/udev/rules.d/10-usb-ethernet-name.rules"
  local NET_USB="/etc/systemd/network/10-usbeth0.network"
  local NET_WIFI="/etc/systemd/network/20-wifi.network"
  local CLOUD_DISABLE="/etc/cloud/cloud.cfg.d/99-disable-network-config.cfg"
  local NETPLAN_CLOUD="/etc/netplan/50-cloud-init.yaml"

  write_file "$UDEV_RULE" \
"SUBSYSTEM==\"net\", ACTION==\"add\", ATTR{address}==\"${USB_MAC}\", NAME=\"${USB_NAME}\""

  run systemctl enable systemd-networkd
  run systemctl enable systemd-networkd.socket || true
  run mkdir -p /etc/systemd/network

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

  write_file "$NET_WIFI" \
"[Match]
Name=${WIFI_GLOB}

[Network]
DHCP=yes

[DHCP]
RouteMetric=${WIFI_METRIC}
"

  run mkdir -p /etc/cloud/cloud.cfg.d
  write_file "$CLOUD_DISABLE" \
"network:
  config: disabled
"

  if [[ -e "$NETPLAN_CLOUD" ]]; then
    backup_if_exists "$NETPLAN_CLOUD"
    run rm -f "$NETPLAN_CLOUD"
    info "Removed: $NETPLAN_CLOUD"
  fi

  run udevadm control --reload
  run systemctl restart systemd-udevd
  run systemctl restart systemd-networkd

  ok "USB Ethernet setup completed."
  echo
  echo "Recommended: reboot to apply rename, then check:"
  echo "  ip link show ${USB_NAME}"
  echo "  networkctl status ${USB_NAME}"
  echo "  ip route | head"
}

final_checks() {
  begin_step "Final checks and summary"
  echo "Log file: $LOG_FILE"
  echo
  ss -lntp | grep -E '(:22[[:space:]]|sshd)' || true
  echo
  ufw status verbose || true
  echo
  systemctl list-unit-files | grep -E 'sleep.target|suspend.target|hibernate.target|hybrid-sleep.target' || true
  echo
  ok "Setup complete."
}

main() {
  require_root
  detect_user
  apt_update_upgrade
  set_timezone
  install_basics
  configure_ssh
  configure_firewall
  disable_sleep_suspend
  ignore_lid_close
  enable_tlp_sensors

  setup_usbeth

  set_static_ip_hint
  final_checks
}

main "$@"