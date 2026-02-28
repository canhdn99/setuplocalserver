#!/usr/bin/env bash
# tui-server-setup.sh
# Run: sudo bash tui-server-setup.sh

set -Eeuo pipefail

# ---------------- Logging ----------------
LOG_DIR="/var/log/24x7-setup"
LOG_FILE="$LOG_DIR/tui-setup-$(date +%F-%H%M%S).log"
mkdir -p "$LOG_DIR"
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

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

# ---------------- UI defaults ----------------
BACKTITLE="Server Setup TUI"
export DIALOGRC=/dev/null

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

# ---------------- Helpers ----------------
backup_if_exists() {
  local f="$1"
  if [[ -e "$f" ]]; then
    local ts
    ts="$(date +%Y%m%d_%H%M%S)"
    cp -a "$f" "${f}.bak_${ts}"
    echo "[INFO] Backup: ${f}.bak_${ts}"
  fi
}

write_file() {
  local path="$1"
  local content="$2"
  backup_if_exists "$path"
  printf "%s\n" "$content" > "$path"
  echo "[INFO] Wrote: $path"
}

run() {
  echo "[INFO] Running: $*"
  "$@"
  echo "[OK] Done: $*"
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
  timedatectl || true
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
  ufw status verbose || true
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
  sensors || true
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
    echo "[INFO] USB Ethernet not enabled, skip"
    return 0
  fi

  if [[ -z "$USB_IFACE" ]]; then
    USB_IFACE="$(pick_usb_iface)"
  fi

  if [[ -z "$USB_IFACE" ]]; then
    echo "[ERROR] Cannot find USB NIC. Run: ip -br link"
    return 1
  fi

  USB_MAC="$(get_mac_of_iface "$USB_IFACE")"
  if [[ -z "$USB_MAC" || "$USB_MAC" == "00:00:00:00:00:00" ]]; then
    echo "[ERROR] Cannot read MAC from $USB_IFACE"
    return 1
  fi

  echo "[INFO] USB NIC: $USB_IFACE"
  echo "[INFO] MAC: $USB_MAC"
  echo "[INFO] Rename to: $USB_NAME"

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

  echo "[OK] USB Ethernet configured. Reboot recommended for rename to apply."
}

# ---------------- Plan ----------------
plan_text() {
  {
    echo "Log: $LOG_FILE"
    echo
    echo "Selected tasks:"
    [[ $SEL_UPDATE -eq 1 ]] && echo "- Update/Upgrade packages"
    [[ $SEL_TZ -eq 1 ]] && echo "- Set timezone Asia/Bangkok"
    [[ $SEL_PKGS -eq 1 ]] && echo "- Install base packages"
    [[ $SEL_SSH -eq 1 ]] && echo "- Configure SSH"
    [[ $SEL_UFW -eq 1 ]] && echo "- Configure UFW"
    [[ $SEL_SLEEP -eq 1 ]] && echo "- Disable sleep/suspend/hibernate"
    [[ $SEL_LID -eq 1 ]] && echo "- Ignore lid close"
    [[ $SEL_TLP -eq 1 ]] && echo "- Enable TLP + sensors"
    [[ $SEL_DISABLE_WAIT_ONLINE -eq 1 ]] && echo "- Disable systemd-networkd-wait-online"

    if [[ $USB_ENABLE -eq 1 ]]; then
      echo "- USB Ethernet setup"
      echo "  - iface: ${USB_IFACE:-auto}"
      echo "  - rename: $USB_NAME"
      echo "  - usb metric: $USB_METRIC"
      echo "  - wifi glob: $WIFI_GLOB"
      echo "  - wifi metric: $WIFI_METRIC"
      echo "  - disable cloud-init network: $USB_DISABLE_CLOUDINIT"
    fi

    echo
    echo "Notes:"
    echo "- USB rename usually needs reboot."
    echo "- Disabling wait-online can speed boot but some services may need tuning."
  } | sed 's/\t/  /g'
}

# ---------------- Header + live log + gauge ----------------
start_live_log_window() {
  # Tail log in a dialog window, keep it visible while gauge runs
  # Capture pid if dialog prints one, then we can kill it at end
  TAIL_PID=""
  local pid_tmp
  pid_tmp="$(mktemp)"
  dialog --backtitle "$BACKTITLE" --title "Realtime Log" --tailboxbg "$LOG_FILE" 18 90 0 0 2>"$pid_tmp" || true
  TAIL_PID="$(grep -Eo '[0-9]+' "$pid_tmp" | head -n1 || true)"
  rm -f "$pid_tmp" || true
}

stop_live_log_window() {
  if [[ -n "${TAIL_PID:-}" ]]; then
    kill "$TAIL_PID" 2>/dev/null || true
  fi
  dialog --clear || true
}

count_steps() {
  local n=0
  [[ $SEL_UPDATE -eq 1 ]] && n=$((n+1))
  [[ $SEL_TZ -eq 1 ]] && n=$((n+1))
  [[ $SEL_PKGS -eq 1 ]] && n=$((n+1))
  [[ $SEL_SSH -eq 1 ]] && n=$((n+1))
  [[ $SEL_UFW -eq 1 ]] && n=$((n+1))
  [[ $SEL_SLEEP -eq 1 ]] && n=$((n+1))
  [[ $SEL_LID -eq 1 ]] && n=$((n+1))
  [[ $SEL_TLP -eq 1 ]] && n=$((n+1))
  [[ $SEL_DISABLE_WAIT_ONLINE -eq 1 ]] && n=$((n+1))
  [[ $USB_ENABLE -eq 1 ]] && n=$((n+1))
  echo "$n"
}

gauge_emit() {
  local pct="$1"
  local msg="$2"
  echo "XXX"
  echo "$pct"
  echo "$msg"
  echo "XXX"
}

run_with_gauge() {
  local total
  total="$(count_steps)"
  if [[ "$total" -le 0 ]]; then
    gauge_emit 0 "No tasks selected"
    sleep 1
    gauge_emit 100 "Done"
    return 0
  fi

  local done=0
  local pct=0

  step() {
    local label="$1"
    local fn="$2"

    done=$((done+1))
    pct=$(( (done * 100) / total ))
    gauge_emit "$pct" "Running: $label"
    "$fn"
    gauge_emit "$pct" "Finished: $label"
  }

  [[ $SEL_UPDATE -eq 1 ]] && step "Update/Upgrade packages" act_update
  [[ $SEL_TZ -eq 1 ]] && step "Set timezone Asia/Bangkok" act_timezone
  [[ $SEL_PKGS -eq 1 ]] && step "Install base packages" act_packages
  [[ $SEL_SSH -eq 1 ]] && step "Configure SSH" act_ssh
  [[ $SEL_UFW -eq 1 ]] && step "Configure UFW" act_ufw
  [[ $SEL_SLEEP -eq 1 ]] && step "Disable sleep/suspend/hibernate" act_disable_sleep
  [[ $SEL_LID -eq 1 ]] && step "Ignore lid close" act_ignore_lid
  [[ $SEL_TLP -eq 1 ]] && step "Enable TLP + sensors" act_tlp_sensors
  [[ $SEL_DISABLE_WAIT_ONLINE -eq 1 ]] && step "Disable networkd wait-online" act_disable_wait_online
  [[ $USB_ENABLE -eq 1 ]] && step "USB Ethernet setup" act_usbeth

  gauge_emit 100 "All done"
  sleep 1
}

# ---------------- TUI screens ----------------
main_menu() {
  dialog --backtitle "$BACKTITLE" --title "Main Menu" --menu "Choose an action" 16 70 8 \
    1 "Configure - choose tasks" \
    2 "USB Ethernet - configure" \
    3 "Show plan" \
    4 "Apply" \
    5 "Exit" \
    3>&1 1>&2 2>&3
}

configure_menu() {
  local out
  out="$(
    dialog --backtitle "$BACKTITLE" --title "Configure tasks" --checklist "Select tasks to apply" 20 78 10 \
      UPDATE "Update/Upgrade packages" $([[ $SEL_UPDATE -eq 1 ]] && echo on || echo off) \
      TZ "Set timezone Asia/Bangkok" $([[ $SEL_TZ -eq 1 ]] && echo on || echo off) \
      PKGS "Install base packages" $([[ $SEL_PKGS -eq 1 ]] && echo on || echo off) \
      SSH "Configure SSH" $([[ $SEL_SSH -eq 1 ]] && echo on || echo off) \
      UFW "Configure UFW firewall" $([[ $SEL_UFW -eq 1 ]] && echo on || echo off) \
      SLEEP "Disable sleep/suspend/hibernate" $([[ $SEL_SLEEP -eq 1 ]] && echo on || echo off) \
      LID "Ignore lid close" $([[ $SEL_LID -eq 1 ]] && echo on || echo off) \
      TLP "Enable TLP + sensors" $([[ $SEL_TLP -eq 1 ]] && echo on || echo off) \
      WAIT "Disable systemd-networkd-wait-online" $([[ $SEL_DISABLE_WAIT_ONLINE -eq 1 ]] && echo on || echo off) \
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
  local choice
  choice="$(
    dialog --backtitle "$BACKTITLE" --title "USB Ethernet" --menu "Configure USB Ethernet options" 18 78 8 \
      1 "Toggle USB Ethernet setup (enable/disable)" \
      2 "Set interface (auto or manual)" \
      3 "Set rename target" \
      4 "Set metrics (usb and wifi)" \
      5 "Toggle disable cloud-init network" \
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
        dialog --backtitle "$BACKTITLE" --title "Interface mode" --menu "Pick selection mode" 14 70 3 \
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
  dialog --backtitle "$BACKTITLE" --title "Plan" --scrolltext --msgbox "$(plan_text)" 22 78
}

apply_all() {
  local txt
  txt="$(plan_text)"
  if ! dialog --backtitle "$BACKTITLE" --title "Confirm Apply" --yesno "Apply these changes?\n\n$txt" 22 78; then
    return 0
  fi

  start_live_log_window

  # Run tasks with progress gauge
  run_with_gauge | dialog --backtitle "$BACKTITLE" --title "Applying" --gauge "Working... (log window is updating)" 10 78 0

  stop_live_log_window

  dialog --backtitle "$BACKTITLE" --title "Done" --msgbox \
"Completed.
Log: $LOG_FILE

Tip: reboot recommended if USB rename was applied." 12 78
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
    5) dialog --clear; exit 0 ;;
  esac
done
