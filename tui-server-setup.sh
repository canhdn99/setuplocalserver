#!/usr/bin/env bash
# tui-server-setup.sh
# Run: sudo bash tui-server-setup.sh

set -Eeuo pipefail

# Fix terminal mode
if [[ -t 0 ]]; then
  export TERM="${TERM:-xterm-256color}"
  stty sane 2>/dev/null || true
fi

# ---------------- Logging ----------------
LOG_DIR="/var/log/24x7-setup"
LOG_FILE="$LOG_DIR/tui-setup-$(date +%F-%H%M%S).log"
mkdir -p "$LOG_DIR"
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"

# Log helper: writes ONLY to log file, never to terminal
log() { printf "[%s] %s\n" "$(date +%H:%M:%S)" "$*" >>"$LOG_FILE"; }

# ---------------- Root check ----------------
if [[ "${EUID}" -ne 0 ]]; then
  echo "[ERROR] Please run: sudo bash $0"
  exit 1
fi

# ---------------- Ensure dialog ----------------
ensure_dialog() {
  if command -v dialog >/dev/null 2>&1; then
    return 0
  fi
  apt-get update
  apt-get install -y dialog
}
ensure_dialog

# ---------------- UI Theme ----------------
setup_theme() {
  local rc
  rc="$(mktemp /tmp/dialogrc.XXXXXX)"
  cat > "$rc" <<'THEME'
# ── Dark Cyan Theme ──
use_shadow = ON
use_colors = ON

screen_color = (CYAN,BLUE,ON)

dialog_color = (WHITE,BLACK,OFF)
title_color = (CYAN,BLACK,ON)
border_color = (CYAN,BLACK,ON)
border2_color = (CYAN,BLACK,ON)

button_active_color = (BLACK,CYAN,ON)
button_inactive_color = (CYAN,BLACK,OFF)
button_key_active_color = (BLACK,CYAN,ON)
button_key_inactive_color = (CYAN,BLACK,ON)
button_label_active_color = (BLACK,CYAN,ON)
button_label_inactive_color = (CYAN,BLACK,OFF)

menubox_color = (WHITE,BLACK,OFF)
menubox_border_color = (CYAN,BLACK,ON)
menubox_border2_color = (CYAN,BLACK,ON)
item_color = (WHITE,BLACK,OFF)
item_selected_color = (BLACK,CYAN,ON)
tag_color = (CYAN,BLACK,ON)
tag_selected_color = (BLACK,CYAN,ON)
tag_key_color = (CYAN,BLACK,ON)
tag_key_selected_color = (BLACK,CYAN,ON)

check_color = (WHITE,BLACK,OFF)
check_selected_color = (BLACK,CYAN,ON)

inputbox_color = (WHITE,BLACK,OFF)
inputbox_border_color = (CYAN,BLACK,ON)
inputbox_border2_color = (CYAN,BLACK,ON)

searchbox_color = (WHITE,BLACK,OFF)
searchbox_title_color = (CYAN,BLACK,ON)
searchbox_border_color = (CYAN,BLACK,ON)
searchbox_border2_color = (CYAN,BLACK,ON)

gauge_color = (BLACK,CYAN,ON)

position_indicator_color = (CYAN,BLACK,ON)
uarrow_color = (CYAN,BLACK,ON)
darrow_color = (CYAN,BLACK,ON)
THEME
  export DIALOGRC="$rc"
  trap 'rm -f "$rc"' EXIT
}
setup_theme

# Dynamic backtitle with system info
build_backtitle() {
  local host ip_addr up_time
  host="$(hostname 2>/dev/null || echo '?')"
  ip_addr="$(hostname -I 2>/dev/null | awk '{print $1}' || echo '?')"
  up_time="$(uptime -p 2>/dev/null || echo '?')"
  local dry_tag=""
  [[ "${DRY_RUN:-0}" -eq 1 ]] && dry_tag="  [DRY-RUN]"
  echo "Server Setup TUI | Host: ${host} | IP: ${ip_addr} | ${up_time}${dry_tag}"
}
BACKTITLE="$(build_backtitle)"

# ---------------- Error trap ----------------
on_err() {
  local ec=$?
  dialog --clear || true
  echo "[ERROR] Failed. Exit: $ec"
  echo "[ERROR] Log: $LOG_FILE"
  tail -n 120 "$LOG_FILE" || true
  exit "$ec"
}
trap on_err ERR

# ---------------- State ----------------
SEL_UPDATE=0
SEL_TZ=0
SEL_PKGS=0
SEL_SSH=0
SEL_UFW=0
SEL_SLEEP=0
SEL_LID=0
SEL_TLP=0
SEL_DISABLE_WAIT_ONLINE=0

USB_ENABLE=0
USB_IFACE=""
USB_MAC=""
USB_NAME="usbeth0"
USB_METRIC="10"
WIFI_GLOB="wlp*"
WIFI_METRIC="600"
USB_DISABLE_CLOUDINIT=1

DRY_RUN=0

# ---------------- Helpers ----------------
backup_if_exists() {
  local f="$1"
  if [[ -e "$f" ]]; then
    local ts
    ts="$(date +%Y%m%d_%H%M%S)"
    if [[ "$DRY_RUN" -eq 1 ]]; then
      log "[DRY-RUN] Would backup: $f -> ${f}.bak_${ts}"
    else
      cp -a "$f" "${f}.bak_${ts}"
      log "Backup: ${f}.bak_${ts}"
    fi
  fi
}

write_file() {
  local path="$1"
  local content="$2"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "[DRY-RUN] Would write: $path"
  else
    backup_if_exists "$path"
    printf "%s\n" "$content" > "$path"
    log "Wrote: $path"
  fi
}

run() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "[DRY-RUN] Would run: $*"
  else
    log "Running: $*"
    "$@" >>"$LOG_FILE" 2>&1
    log "Done: $*"
  fi
}

# ---------------- Actions ----------------
act_update() {
  run apt-get update
  run apt-get -y upgrade
  run apt-get -y autoremove
}

act_timezone() {
  if timedatectl list-timezones | grep -qx "Asia/Bangkok"; then
    run timedatectl set-timezone "Asia/Bangkok"
  fi
  timedatectl >>"$LOG_FILE" 2>&1 || true
}

act_packages() {
  run apt-get install -y \
    openssh-server ufw curl wget nano \
    net-tools iproute2 netcat-openbsd \
    lm-sensors tlp
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

  run sshd -t
  run systemctl restart ssh
}

act_ufw() {
  run ufw allow OpenSSH || true
  run ufw allow 22/tcp || true
  run ufw default deny incoming
  run ufw default allow outgoing
  run ufw --force enable
  ufw status verbose >>"$LOG_FILE" 2>&1 || true
}

act_disable_sleep() {
  run systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
}

act_ignore_lid() {
  local cfg="/etc/systemd/logind.conf"
  [[ -f "$cfg" ]] && run cp -a "$cfg" "${cfg}.bak.$(date +%F-%H%M%S)" || true

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
}

act_tlp_sensors() {
  run systemctl enable tlp
  run systemctl start tlp
  run sensors-detect --auto || true
  sensors >>"$LOG_FILE" 2>&1 || true
}

act_disable_wait_online() {
  run systemctl disable --now systemd-networkd-wait-online.service || true
  run systemctl mask systemd-networkd-wait-online.service || true
}

# ---------------- USB Ethernet helpers ----------------
is_skip_iface() {
  local n="$1"
  [[ "$n" == "lo" ]] && return 0
  [[ "$n" == docker* ]] && return 0
  [[ "$n" == br-* ]] && return 0
  [[ "$n" == veth* ]] && return 0
  [[ "$n" == virbr* ]] && return 0
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

act_usbeth() {
  if [[ "$USB_ENABLE" -ne 1 ]]; then
    log "USB Ethernet not enabled, skip"
    return 0
  fi

  if [[ -z "$USB_IFACE" ]]; then
    USB_IFACE="$(pick_usb_iface)"
  fi

  if [[ -z "$USB_IFACE" ]]; then
    log "[ERROR] Cannot find USB NIC"
    return 1
  fi

  USB_MAC="$(get_mac_of_iface "$USB_IFACE")"
  if [[ -z "$USB_MAC" || "$USB_MAC" == "00:00:00:00:00:00" ]]; then
    log "[ERROR] Cannot read MAC from $USB_IFACE"
    return 1
  fi

  log "USB NIC: $USB_IFACE  MAC: $USB_MAC  Rename to: $USB_NAME"

  local UDEV_RULE="/etc/udev/rules.d/10-usb-ethernet-name.rules"
  local NET_USB="/etc/systemd/network/10-usbeth.network"
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

  if [[ "$USB_DISABLE_CLOUDINIT" -eq 1 ]]; then
    run mkdir -p /etc/cloud/cloud.cfg.d
    write_file "$CLOUD_DISABLE" \
"network:
  config: disabled
"
    if [[ -e "$NETPLAN_CLOUD" ]]; then
      backup_if_exists "$NETPLAN_CLOUD"
      run rm -f "$NETPLAN_CLOUD"
    fi
  fi

  run udevadm control --reload
  run systemctl restart systemd-udevd
  run systemctl restart systemd-networkd

  log "USB Ethernet configured. Reboot recommended."
}

# ---------------- Plan ----------------
plan_text() {
  {
    echo "========================================"
    echo "          Execution Plan"
    echo "========================================"
    echo
    echo "Log: $LOG_FILE"
    echo
    echo "Selected tasks:"
    [[ $SEL_UPDATE -eq 1 ]] && echo "  [+] Update/Upgrade packages"
    [[ $SEL_TZ -eq 1 ]] && echo "  [+] Set timezone Asia/Bangkok"
    [[ $SEL_PKGS -eq 1 ]] && echo "  [+] Install base packages"
    [[ $SEL_SSH -eq 1 ]] && echo "  [+] Configure SSH (harden)"
    [[ $SEL_UFW -eq 1 ]] && echo "  [+] Configure UFW firewall"
    [[ $SEL_SLEEP -eq 1 ]] && echo "  [+] Disable sleep/suspend/hibernate"
    [[ $SEL_LID -eq 1 ]] && echo "  [+] Ignore lid close"
    [[ $SEL_TLP -eq 1 ]] && echo "  [+] Enable TLP + sensors"
    [[ $SEL_DISABLE_WAIT_ONLINE -eq 1 ]] && echo "  [+] Disable systemd-networkd-wait-online"

    if [[ $USB_ENABLE -eq 1 ]]; then
      echo "  [+] USB Ethernet setup"
      echo "      |-- iface: ${USB_IFACE:-auto}"
      echo "      |-- rename: $USB_NAME"
      echo "      |-- usb metric: $USB_METRIC"
      echo "      |-- wifi glob: $WIFI_GLOB"
      echo "      |-- wifi metric: $WIFI_METRIC"
      echo "      +-- disable cloud-init: $USB_DISABLE_CLOUDINIT"
    fi

    local cnt
    cnt="$(count_selected)"
    echo
    echo "----------------------------------------"
    echo "Total: ${cnt} task(s) selected"
    echo
    echo "Notes:"
    echo "  * USB rename usually needs reboot."
    echo "  * Disabling wait-online speeds boot but may affect some services."
  } | sed 's/\t/  /g'
}

# ---------------- Mixed gauge progress ----------------
# Task list definition: tag, label, selection variable, action function
TASK_TAGS=(UPDATE TZ PKGS SSH UFW SLEEP LID TLP WAIT USB)
TASK_LABELS=(
  "Update/Upgrade packages"
  "Set timezone Asia/Bangkok"
  "Install base packages"
  "Configure SSH (harden)"
  "Configure UFW firewall"
  "Disable sleep/suspend/hibernate"
  "Ignore lid close"
  "Enable TLP + sensors"
  "Disable networkd wait-online"
  "USB Ethernet setup"
)
TASK_FUNCTIONS=(act_update act_timezone act_packages act_ssh act_ufw act_disable_sleep act_ignore_lid act_tlp_sensors act_disable_wait_online act_usbeth)

# Status codes for dialog --mixedgauge:
#   0=Succeeded  1=Failed  5=Done  6=Skipped  7=In Progress  8=Pending  9=N/A
declare -A TASK_STATUS

is_task_selected() {
  local tag="$1"
  case "$tag" in
    UPDATE) [[ $SEL_UPDATE -eq 1 ]] ;;
    TZ) [[ $SEL_TZ -eq 1 ]] ;;
    PKGS) [[ $SEL_PKGS -eq 1 ]] ;;
    SSH) [[ $SEL_SSH -eq 1 ]] ;;
    UFW) [[ $SEL_UFW -eq 1 ]] ;;
    SLEEP) [[ $SEL_SLEEP -eq 1 ]] ;;
    LID) [[ $SEL_LID -eq 1 ]] ;;
    TLP) [[ $SEL_TLP -eq 1 ]] ;;
    WAIT) [[ $SEL_DISABLE_WAIT_ONLINE -eq 1 ]] ;;
    USB) [[ $USB_ENABLE -eq 1 ]] ;;
    *) return 1 ;;
  esac
}

count_selected() {
  local n=0
  for tag in "${TASK_TAGS[@]}"; do
    is_task_selected "$tag" && n=$((n+1))
  done
  echo "$n"
}

show_mixed_gauge() {
  local pct="$1"
  local msg="$2"
  local args=()
  for i in "${!TASK_TAGS[@]}"; do
    local tag="${TASK_TAGS[$i]}"
    local label="${TASK_LABELS[$i]}"
    local st="${TASK_STATUS[$tag]:-9}"
    args+=("$label" "$st")
  done
  dialog --backtitle "$BACKTITLE" --title " Applying " \
    --mixedgauge "$msg" 22 78 "$pct" "${args[@]}" 2>/dev/null || true
}

run_all_tasks() {
  local total
  total="$(count_selected)"
  if [[ "$total" -le 0 ]]; then
    dialog --backtitle "$BACKTITLE" --title " No Tasks " --msgbox "No tasks selected." 8 40
    return 0
  fi

  # Init all statuses
  for tag in "${TASK_TAGS[@]}"; do
    if is_task_selected "$tag"; then
      TASK_STATUS[$tag]=8   # Pending
    else
      TASK_STATUS[$tag]=9   # N/A
    fi
  done

  local completed=0

  do_task() {
    local tag="$1"
    local fn="$2"

    if ! is_task_selected "$tag"; then
      return 0
    fi

    local pct=$(( completed * 100 / total ))
    TASK_STATUS[$tag]=7   # In Progress
    show_mixed_gauge "$pct" "Running: ${TASK_LABELS[$3]}..."

    if "$fn" 2>&1; then
      TASK_STATUS[$tag]=0  # Succeeded
    else
      TASK_STATUS[$tag]=1  # Failed
    fi

    completed=$((completed+1))
    pct=$(( completed * 100 / total ))
    show_mixed_gauge "$pct" "Completed: ${TASK_LABELS[$3]}"
    sleep 0.3
  }

  for i in "${!TASK_TAGS[@]}"; do
    do_task "${TASK_TAGS[$i]}" "${TASK_FUNCTIONS[$i]}" "$i"
  done

  show_mixed_gauge 100 "All tasks finished!"
  sleep 1
}

# ---------------- Post-apply summary ----------------
build_summary() {
  local si
  si() {
    case "${TASK_STATUS[$1]:-9}" in
      0) echo "[OK]" ;;
      1) echo "[FAIL]" ;;
      *) echo "[--]" ;;
    esac
  }
  {
    echo "========================================"
    echo "          Setup Summary"
    echo "========================================"
    echo
    echo "  Time: $(date '+%F %T')"
    echo "  Log:  $LOG_FILE"
    echo

    if [[ $SEL_UPDATE -eq 1 ]]; then
      echo "$(si UPDATE) Update/Upgrade"
      echo
    fi

    if [[ $SEL_TZ -eq 1 ]]; then
      echo "$(si TZ) Timezone"
      echo "    +-- $(timedatectl show -p Timezone --value 2>/dev/null || echo 'unknown')"
      echo
    fi

    if [[ $SEL_PKGS -eq 1 ]]; then
      echo "$(si PKGS) Packages installed"
      echo "    +-- openssh-server, ufw, curl, wget, nano,"
      echo "        net-tools, lm-sensors, tlp, smartmontools"
      echo
    fi

    if [[ $SEL_SSH -eq 1 ]]; then
      echo "$(si SSH) SSH"
      echo "    |-- PermitRootLogin: $(grep -m1 '^PermitRootLogin' /etc/ssh/sshd_config 2>/dev/null || echo '-')"
      echo "    |-- PasswordAuth:    $(grep -m1 '^PasswordAuthentication' /etc/ssh/sshd_config 2>/dev/null || echo '-')"
      echo "    |-- PubkeyAuth:      $(grep -m1 '^PubkeyAuthentication' /etc/ssh/sshd_config 2>/dev/null || echo '-')"
      echo "    |-- Service:         $(systemctl is-active ssh 2>/dev/null || echo '-')"
      echo "    +-- Port:            $(ss -lntp 2>/dev/null | grep -oP ':\K22(?=\s)' | head -1 || echo '22')"
      echo
    fi

    if [[ $SEL_UFW -eq 1 ]]; then
      echo "$(si UFW) UFW Firewall"
      echo "    |-- $(ufw status 2>/dev/null | head -1 || echo '-')"
      echo "    |-- Default in:  deny"
      echo "    |-- Default out: allow"
      echo "    +-- Allowed:     OpenSSH, 22/tcp"
      echo
    fi

    if [[ $SEL_SLEEP -eq 1 ]]; then
      echo "$(si SLEEP) Sleep/Suspend -> all masked"
      echo
    fi

    if [[ $SEL_LID -eq 1 ]]; then
      echo "$(si LID) Lid Close -> ignore"
      echo
    fi

    if [[ $SEL_TLP -eq 1 ]]; then
      echo "$(si TLP) TLP -> $(systemctl is-active tlp 2>/dev/null || echo '-')"
      echo
    fi

    if [[ $SEL_DISABLE_WAIT_ONLINE -eq 1 ]]; then
      echo "$(si WAIT) Wait-Online -> masked"
      echo
    fi

    if [[ $USB_ENABLE -eq 1 ]]; then
      echo "$(si USB) USB Ethernet"
      echo "    |-- Interface:  ${USB_IFACE:-auto-detected}"
      echo "    |-- MAC:        ${USB_MAC:-unknown}"
      echo "    |-- Renamed to: $USB_NAME"
      echo "    |-- USB metric: $USB_METRIC"
      echo "    |-- WiFi glob:  $WIFI_GLOB"
      echo "    |-- WiFi metric:$WIFI_METRIC"
      echo "    +-- Cloud-init: disabled=$USB_DISABLE_CLOUDINIT"
      echo
    fi

    echo "----------------------------------------"
    echo "Network Info"
    echo "----------------------------------------"
    ip -br a 2>/dev/null || true
    echo
    ip route 2>/dev/null | head -5 || true
    echo
    echo "Tip: Reboot recommended if USB rename was applied."
  }
}

# ---------------- TUI screens ----------------
main_menu() {
  BACKTITLE="$(build_backtitle)"
  local dry_label="OFF"
  [[ "$DRY_RUN" -eq 1 ]] && dry_label="ON"
  dialog --backtitle "$BACKTITLE" --title " Main Menu " --menu \
    "\nSelect an action:\n" 20 72 9 \
    1 "Configure -- choose tasks" \
    2 "USB Ethernet -- configure" \
    3 "Show plan" \
    4 "Apply selected tasks" \
    5 "Dry-run mode  [${dry_label}]" \
    6 "Tail log" \
    7 "Exit" \
    3>&1 1>&2 2>&3
}

configure_menu() {
  local out
  out="$(
    dialog --backtitle "$BACKTITLE" --title " Configure Tasks " --checklist \
      "\nUse SPACE to toggle, ENTER to confirm:\n" 22 78 10 \
      UPDATE "Update/Upgrade packages" $([[ $SEL_UPDATE -eq 1 ]] && echo on || echo off) \
      TZ "Set timezone Asia/Bangkok" $([[ $SEL_TZ -eq 1 ]] && echo on || echo off) \
      PKGS "Install base packages" $([[ $SEL_PKGS -eq 1 ]] && echo on || echo off) \
      SSH "Configure SSH (harden)" $([[ $SEL_SSH -eq 1 ]] && echo on || echo off) \
      UFW "Configure UFW firewall" $([[ $SEL_UFW -eq 1 ]] && echo on || echo off) \
      SLEEP "Disable sleep/suspend/hibernate" $([[ $SEL_SLEEP -eq 1 ]] && echo on || echo off) \
      LID "Ignore lid close" $([[ $SEL_LID -eq 1 ]] && echo on || echo off) \
      TLP "Enable TLP + sensors" $([[ $SEL_TLP -eq 1 ]] && echo on || echo off) \
      WAIT "Disable networkd wait-online" $([[ $SEL_DISABLE_WAIT_ONLINE -eq 1 ]] && echo on || echo off) \
      3>&1 1>&2 2>&3
  )" || return 0

  SEL_UPDATE=0; SEL_TZ=0; SEL_PKGS=0; SEL_SSH=0; SEL_UFW=0; SEL_SLEEP=0; SEL_LID=0; SEL_TLP=0; SEL_DISABLE_WAIT_ONLINE=0

  for c in $out; do
    c="${c//\"/}"
    case "$c" in
      UPDATE) SEL_UPDATE=1 ;;
      TZ) SEL_TZ=1 ;;
      PKGS) SEL_PKGS=1 ;;
      SSH) SEL_SSH=1 ;;
      UFW) SEL_UFW=1 ;;
      SLEEP) SEL_SLEEP=1 ;;
      LID) SEL_LID=1 ;;
      TLP) SEL_TLP=1 ;;
      WAIT) SEL_DISABLE_WAIT_ONLINE=1 ;;
    esac
  done
}

usb_menu() {
  local usb_st="OFF"
  [[ $USB_ENABLE -eq 1 ]] && usb_st="ON"
  local choice
  choice="$(
    dialog --backtitle "$BACKTITLE" --title " USB Ethernet [${usb_st}] " --menu \
      "\nConfigure USB Ethernet options:\n" 20 78 8 \
      1 "Toggle enable/disable  [${usb_st}]" \
      2 "Set interface (${USB_IFACE:-auto})" \
      3 "Set rename target (${USB_NAME})" \
      4 "Set metrics (USB:${USB_METRIC} WiFi:${WIFI_METRIC})" \
      5 "Toggle cloud-init disable ($([[ $USB_DISABLE_CLOUDINIT -eq 1 ]] && echo ON || echo OFF))" \
      6 "Back" \
      3>&1 1>&2 2>&3
  )" || return 0

  case "$choice" in
    1)
      if [[ $USB_ENABLE -eq 1 ]]; then USB_ENABLE=0; else USB_ENABLE=1; fi
      ;;
    2)
      local mode
      mode="$(
        dialog --backtitle "$BACKTITLE" --title " Interface Mode " --menu "\nPick selection mode:" 14 70 3 \
          AUTO "Auto detect USB NIC" \
          MANUAL "Specify interface name" \
          BACK "Back" \
          3>&1 1>&2 2>&3
      )" || return 0
      if [[ "$mode" == "AUTO" ]]; then
        USB_IFACE=""
      elif [[ "$mode" == "MANUAL" ]]; then
        USB_IFACE="$(
          dialog --backtitle "$BACKTITLE" --title "Interface" --inputbox \
            "Enter interface name (example: enx..., enp...)\nTip: check with: ip -br link" 12 70 "${USB_IFACE}" \
            3>&1 1>&2 2>&3
        )" || true
      fi
      ;;
    3)
      USB_NAME="$(
        dialog --backtitle "$BACKTITLE" --title "Rename target" --inputbox \
          "Enter new interface name" 10 70 "${USB_NAME}" \
          3>&1 1>&2 2>&3
      )" || true
      ;;
    4)
      USB_METRIC="$(
        dialog --backtitle "$BACKTITLE" --title "USB metric" --inputbox \
          "Enter RouteMetric for USB Ethernet (lower preferred)" 10 70 "${USB_METRIC}" \
          3>&1 1>&2 2>&3
      )" || true
      WIFI_GLOB="$(
        dialog --backtitle "$BACKTITLE" --title "WiFi glob" --inputbox \
          "Enter WiFi interface glob (example: wlp*)" 10 70 "${WIFI_GLOB}" \
          3>&1 1>&2 2>&3
      )" || true
      WIFI_METRIC="$(
        dialog --backtitle "$BACKTITLE" --title "WiFi metric" --inputbox \
          "Enter RouteMetric for WiFi (higher less preferred)" 10 70 "${WIFI_METRIC}" \
          3>&1 1>&2 2>&3
      )" || true
      ;;
    5)
      if [[ $USB_DISABLE_CLOUDINIT -eq 1 ]]; then USB_DISABLE_CLOUDINIT=0; else USB_DISABLE_CLOUDINIT=1; fi
      ;;
    6) return 0 ;;
  esac

  dialog --backtitle "$BACKTITLE" --title "USB Ethernet status" --msgbox \
"Enabled: $USB_ENABLE
Interface: ${USB_IFACE:-auto}
Rename: $USB_NAME
USB metric: $USB_METRIC
WiFi glob: $WIFI_GLOB
WiFi metric: $WIFI_METRIC
Disable cloud-init network: $USB_DISABLE_CLOUDINIT" 14 70
}

show_plan() {
  dialog --backtitle "$BACKTITLE" --title " Execution Plan " --scrolltext --msgbox "$(plan_text)" 24 80
}

tail_log() {
  dialog --backtitle "$BACKTITLE" --title " Log " --tailbox "$LOG_FILE" 22 90 || true
}

apply_all() {
  local txt
  txt="$(plan_text)"
  local mode_tag=""
  [[ "$DRY_RUN" -eq 1 ]] && mode_tag="\n\n[DRY-RUN] No changes will be made"
  if ! dialog --backtitle "$BACKTITLE" --title " Confirm Apply " --yesno "Apply these changes?${mode_tag}\n\n$txt" 26 80; then
    return 0
  fi

  run_all_tasks

  # Show detailed summary
  local summary
  summary="$(build_summary)"
  local sum_title=" Setup Summary "
  [[ "$DRY_RUN" -eq 1 ]] && sum_title=" Dry-Run Summary "
  dialog --backtitle "$BACKTITLE" --title "$sum_title" --scrolltext --msgbox "$summary" 28 82
}

# ---------------- Loop ----------------
while true; do
  choice="$(main_menu)" || exit 0
  case "$choice" in
    1) configure_menu ;;
    2)
      while true; do
        usb_menu || break
        if ! dialog --backtitle "$BACKTITLE" --title "USB Ethernet" --yesno "Back to USB menu?" 8 40; then
          break
        fi
      done
      ;;
    3) show_plan ;;
    4) apply_all ;;
    5)
      if [[ "$DRY_RUN" -eq 1 ]]; then DRY_RUN=0; else DRY_RUN=1; fi
      ;;
    6) tail_log ;;
    7) dialog --clear; exit 0 ;;
  esac
done