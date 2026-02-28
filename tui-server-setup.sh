#!/usr/bin/env bash
# tui-simple.sh
# Run: sudo -E bash tui-simple.sh

set -Eeuo pipefail

# ---------- root ----------
if [[ "${EUID}" -ne 0 ]]; then
  echo "Run: sudo -E bash $0"
  exit 1
fi

# ---------- log ----------
LOG_DIR="/var/log/24x7-setup"
LOG_FILE="$LOG_DIR/tui-simple-$(date +%F-%H%M%S).log"
mkdir -p "$LOG_DIR"
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"

log() { printf "%s %s\n" "[$(date +%H:%M:%S)]" "$*" | tee -a "$LOG_FILE" >/dev/null; }

# ---------- terminal ----------
if [[ -t 0 ]]; then
  stty sane 2>/dev/null || true
fi

# ---------- state ----------
SEL_UPDATE=0
SEL_TZ=0
SEL_PKGS=0
SEL_SSH=0
SEL_UFW=0
SEL_SLEEP=0
SEL_LID=0
SEL_TLP=0
SEL_WAIT=0
SEL_USB=0

USB_NAME="usbeth0"
USB_METRIC="10"
WIFI_GLOB="wlp*"
WIFI_METRIC="600"
USB_DISABLE_CLOUDINIT=1
USB_IFACE=""

# ---------- helpers ----------
toggle() { local v="$1"; if [[ "$v" -eq 1 ]]; then echo 0; else echo 1; fi; }
onoff() { [[ "$1" -eq 1 ]] && echo "ON" || echo "OFF"; }
hr() { printf "%0.s-" {1..78}; echo; }

backup_if_exists() {
  local f="$1"
  if [[ -e "$f" ]]; then
    cp -a "$f" "${f}.bak_$(date +%Y%m%d_%H%M%S)"
    log "[INFO] Backup $f"
  fi
}

write_file() {
  local path="$1"
  local content="$2"
  backup_if_exists "$path"
  printf "%s\n" "$content" > "$path"
  log "[INFO] Wrote $path"
}

run() {
  log "[INFO] Running: $*"
  "$@" >>"$LOG_FILE" 2>&1
  log "[OK] Done: $*"
}

# ---------- actions ----------
act_update() { run apt-get update; run apt-get -y upgrade; run apt-get -y autoremove; }

act_timezone() {
  if timedatectl list-timezones | grep -qx "Asia/Bangkok"; then
    run timedatectl set-timezone "Asia/Bangkok"
  else
    log "[WARN] Asia/Bangkok not found, skip"
  fi
  timedatectl >>"$LOG_FILE" 2>&1 || true
}

act_packages() {
  run apt-get install -y openssh-server ufw curl wget nano net-tools iproute2 netcat-openbsd lm-sensors tlp
  run apt-get install -y smartmontools || true
}

act_ssh() {
  run systemctl enable ssh
  run systemctl start ssh
  local cfg="/etc/ssh/sshd_config"
  [[ -f "$cfg" ]] && run cp -a "$cfg" "${cfg}.bak.$(date +%F-%H%M%S)"
  if ! grep -qE '^[[:space:]]*PermitRootLogin[[:space:]]+' "$cfg"; then
    echo "PermitRootLogin no" >> "$cfg"
  else
    sed -i 's/^[[:space:]]*#\{0,1\}[[:space:]]*PermitRootLogin[[:space:]].*/PermitRootLogin no/' "$cfg"
  fi
  run sshd -t
  run systemctl restart ssh
}

act_ufw() {
  run ufw allow OpenSSH || true
  run ufw allow 22/tcp || true
  run ufw default deny incoming
  run ufw default allow outgoing
  run ufw --force enable
}

act_sleep() { run systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target; }

act_lid() {
  local cfg="/etc/systemd/logind.conf"
  [[ -f "$cfg" ]] && run cp -a "$cfg" "${cfg}.bak.$(date +%F-%H%M%S)" || true
  grep -qE '^\[Login\]' "$cfg" || echo "[Login]" >> "$cfg"
  if grep -qE '^[[:space:]]*HandleLidSwitch=' "$cfg"; then
    sed -i 's/^[[:space:]]*HandleLidSwitch=.*/HandleLidSwitch=ignore/' "$cfg"
  else
    echo "HandleLidSwitch=ignore" >> "$cfg"
  fi
  run systemctl restart systemd-logind
}

act_tlp() { run systemctl enable tlp; run systemctl start tlp; run sensors-detect --auto || true; }

act_wait() {
  run systemctl disable --now systemd-networkd-wait-online.service || true
  run systemctl mask systemd-networkd-wait-online.service || true
}

is_usb_nic() {
  local n="$1"
  udevadm info -q property -p "/sys/class/net/${n}" 2>/dev/null | grep -qx 'ID_BUS=usb'
}

pick_usb_iface() {
  for d in /sys/class/net/*; do
    local n
    n="$(basename "$d")"
    [[ "$n" == "lo" ]] && continue
    [[ "$n" == wl* ]] && continue
    [[ "$n" == docker* ]] && continue
    [[ "$n" == br-* ]] && continue
    [[ "$n" == veth* ]] && continue
    if is_usb_nic "$n"; then
      echo "$n"
      return 0
    fi
  done
  echo ""
}

act_usb() {
  local iface="$USB_IFACE"
  [[ -z "$iface" ]] && iface="$(pick_usb_iface)"
  if [[ -z "$iface" ]]; then
    log "[ERROR] Cannot find USB NIC. Check: ip -br link"
    return 1
  fi
  local mac
  mac="$(cat "/sys/class/net/${iface}/address" 2>/dev/null || true)"
  if [[ -z "$mac" ]]; then
    log "[ERROR] Cannot read MAC from $iface"
    return 1
  fi

  log "[INFO] USB iface $iface MAC $mac rename $USB_NAME"

  write_file "/etc/udev/rules.d/10-usb-ethernet-name.rules" \
"SUBSYSTEM==\"net\", ACTION==\"add\", ATTR{address}==\"${mac}\", NAME=\"${USB_NAME}\""

  run systemctl enable systemd-networkd
  run mkdir -p /etc/systemd/network

  write_file "/etc/systemd/network/10-usbeth.network" \
"[Match]
Name=${USB_NAME}

[Link]
RequiredForOnline=no

[Network]
DHCP=yes

[DHCP]
RouteMetric=${USB_METRIC}
"

  write_file "/etc/systemd/network/20-wifi.network" \
"[Match]
Name=${WIFI_GLOB}

[Network]
DHCP=yes

[DHCP]
RouteMetric=${WIFI_METRIC}
"

  if [[ "$USB_DISABLE_CLOUDINIT" -eq 1 ]]; then
    run mkdir -p /etc/cloud/cloud.cfg.d
    write_file "/etc/cloud/cloud.cfg.d/99-disable-network-config.cfg" \
"network:
  config: disabled
"
    [[ -e /etc/netplan/50-cloud-init.yaml ]] && rm -f /etc/netplan/50-cloud-init.yaml
  fi

  run udevadm control --reload
  run systemctl restart systemd-udevd
  run systemctl restart systemd-networkd
  log "[OK] USB configured, reboot recommended"
}

# ---------- UI ----------
header() {
  clear
  local host uptime now
  host="$(hostname)"
  uptime="$(uptime -p 2>/dev/null || true)"
  now="$(date '+%F %T')"
  echo "$BACKTITLE"
  echo "Host: $host  Time: $now  Uptime: $uptime"
  echo "Log: $LOG_FILE"
  hr
}

show_menu() {
  header
  echo "Toggle tasks by number. Press a to apply, p to show plan, u for USB settings, q to quit."
  echo
  printf " 1) Update/Upgrade                  [%s]\n" "$(onoff "$SEL_UPDATE")"
  printf " 2) Timezone Asia/Bangkok           [%s]\n" "$(onoff "$SEL_TZ")"
  printf " 3) Install base packages           [%s]\n" "$(onoff "$SEL_PKGS")"
  printf " 4) Configure SSH                   [%s]\n" "$(onoff "$SEL_SSH")"
  printf " 5) Configure UFW                   [%s]\n" "$(onoff "$SEL_UFW")"
  printf " 6) Disable sleep/suspend           [%s]\n" "$(onoff "$SEL_SLEEP")"
  printf " 7) Ignore lid close                [%s]\n" "$(onoff "$SEL_LID")"
  printf " 8) Enable TLP + sensors            [%s]\n" "$(onoff "$SEL_TLP")"
  printf " 9) Disable networkd wait-online    [%s]\n" "$(onoff "$SEL_WAIT")"
  printf "10) USB Ethernet setup              [%s]\n" "$(onoff "$SEL_USB")"
  hr
  echo "Key: 1-0 toggle | u USB config | p plan | a apply | l tail log | q quit"
  echo -n "> "
}

plan() {
  header
  echo "Selected:"
  [[ $SEL_UPDATE -eq 1 ]] && echo "- Update/Upgrade"
  [[ $SEL_TZ -eq 1 ]] && echo "- Timezone Asia/Bangkok"
  [[ $SEL_PKGS -eq 1 ]] && echo "- Install packages"
  [[ $SEL_SSH -eq 1 ]] && echo "- SSH"
  [[ $SEL_UFW -eq 1 ]] && echo "- UFW"
  [[ $SEL_SLEEP -eq 1 ]] && echo "- Disable sleep"
  [[ $SEL_LID -eq 1 ]] && echo "- Lid ignore"
  [[ $SEL_TLP -eq 1 ]] && echo "- TLP + sensors"
  [[ $SEL_WAIT -eq 1 ]] && echo "- Disable networkd wait-online"
  if [[ $SEL_USB -eq 1 ]]; then
    echo "- USB Ethernet"
    echo "  - iface: ${USB_IFACE:-auto}"
    echo "  - rename: $USB_NAME"
    echo "  - usb metric: $USB_METRIC"
    echo "  - wifi glob: $WIFI_GLOB"
    echo "  - wifi metric: $WIFI_METRIC"
    echo "  - disable cloud-init: $USB_DISABLE_CLOUDINIT"
  fi
  hr
  read -r -p "Press Enter to go back " _
}

usb_settings() {
  while true; do
    header
    echo "USB settings"
    echo
    echo "1) USB iface (empty = auto): ${USB_IFACE:-auto}"
    echo "2) Rename target: $USB_NAME"
    echo "3) USB metric: $USB_METRIC"
    echo "4) WiFi glob: $WIFI_GLOB"
    echo "5) WiFi metric: $WIFI_METRIC"
    echo "6) Disable cloud-init network: $USB_DISABLE_CLOUDINIT"
    echo
    echo "b) back"
    echo -n "> "
    IFS= read -r key
    case "$key" in
      1) read -r -p "Enter iface (empty = auto): " USB_IFACE ;;
      2) read -r -p "Enter new name: " USB_NAME ;;
      3) read -r -p "Enter USB metric: " USB_METRIC ;;
      4) read -r -p "Enter WiFi glob: " WIFI_GLOB ;;
      5) read -r -p "Enter WiFi metric: " WIFI_METRIC ;;
      6) USB_DISABLE_CLOUDINIT=$([[ "$USB_DISABLE_CLOUDINIT" -eq 1 ]] && echo 0 || echo 1) ;;
      b|B) return 0 ;;
    esac
  done
}

progress_bar() {
  local pct="$1"
  local w=40
  local filled=$(( pct * w / 100 ))
  local empty=$(( w - filled ))
  printf "\rProgress: ["
  printf "%0.s#" $(seq 1 "$filled" 2>/dev/null) 2>/dev/null || true
  printf "%0.s-" $(seq 1 "$empty" 2>/dev/null) 2>/dev/null || true
  printf "] %3d%%" "$pct"
}

apply() {
  header
  echo "Applying... log is writing to $LOG_FILE"
  hr

  local steps=0 done=0
  for v in $SEL_UPDATE $SEL_TZ $SEL_PKGS $SEL_SSH $SEL_UFW $SEL_SLEEP $SEL_LID $SEL_TLP $SEL_WAIT $SEL_USB; do
    [[ "$v" -eq 1 ]] && steps=$((steps+1))
  done
  [[ "$steps" -eq 0 ]] && { echo "No tasks selected"; read -r -p "Enter to continue " _; return 0; }

  do_step() {
    local name="$1"
    shift
    done=$((done+1))
    local pct=$(( done * 100 / steps ))
    echo
    echo "[STEP] $name"
    "$@"
    progress_bar "$pct"
    echo
  }

  [[ $SEL_UPDATE -eq 1 ]] && do_step "Update/Upgrade" act_update
  [[ $SEL_TZ -eq 1 ]] && do_step "Timezone" act_timezone
  [[ $SEL_PKGS -eq 1 ]] && do_step "Install packages" act_packages
  [[ $SEL_SSH -eq 1 ]] && do_step "SSH" act_ssh
  [[ $SEL_UFW -eq 1 ]] && do_step "UFW" act_ufw
  [[ $SEL_SLEEP -eq 1 ]] && do_step "Disable sleep" act_sleep
  [[ $SEL_LID -eq 1 ]] && do_step "Ignore lid" act_lid
  [[ $SEL_TLP -eq 1 ]] && do_step "TLP + sensors" act_tlp
  [[ $SEL_WAIT -eq 1 ]] && do_step "Disable wait-online" act_wait
  [[ $SEL_USB -eq 1 ]] && do_step "USB Ethernet" act_usb

  echo
  echo "Done. Log: $LOG_FILE"
  read -r -p "Press Enter to continue " _
}

tail_log() {
  header
  echo "Realtime log view. Press Ctrl+C to go back."
  hr
  tail -n 200 -f "$LOG_FILE"
}

BACKTITLE="Server Setup TUI"

# ---------- main loop ----------
while true; do
  show_menu
  IFS= read -r key
  case "$key" in
    1) SEL_UPDATE=$(toggle "$SEL_UPDATE") ;;
    2) SEL_TZ=$(toggle "$SEL_TZ") ;;
    3) SEL_PKGS=$(toggle "$SEL_PKGS") ;;
    4) SEL_SSH=$(toggle "$SEL_SSH") ;;
    5) SEL_UFW=$(toggle "$SEL_UFW") ;;
    6) SEL_SLEEP=$(toggle "$SEL_SLEEP") ;;
    7) SEL_LID=$(toggle "$SEL_LID") ;;
    8) SEL_TLP=$(toggle "$SEL_TLP") ;;
    9) SEL_WAIT=$(toggle "$SEL_WAIT") ;;
    0) SEL_USB=$(toggle "$SEL_USB") ;;   # phím 0 đại diện mục 10
    u|U) usb_settings ;;
    p|P) plan ;;
    a|A) apply ;;
    l|L) tail_log ;;
    q|Q) clear; exit 0 ;;
  esac
done
