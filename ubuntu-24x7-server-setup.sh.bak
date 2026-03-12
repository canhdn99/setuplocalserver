#!/usr/bin/env bash
# ubuntu-24x7-server-setup.sh
# Setup Ubuntu Server laptop as 24/7 server with detailed step logs.
# Run as root: sudo bash ubuntu-24x7-server-setup.sh

set -Eeuo pipefail

LOG_DIR="/var/log/24x7-setup"
LOG_FILE="$LOG_DIR/setup-$(date +%F-%H%M%S).log"

mkdir -p "$LOG_DIR"
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"

# Mirror all output to log
exec > >(tee -a "$LOG_FILE") 2>&1

# Colors (safe if no tty)
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
  # Run a command with logging and explicit exit check
  info "Running: $*"
  "$@"
  ok "Done: $*"
}

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
  # Prefer SUDO_USER if present, else first user with home dir under /home
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
    warn "Timezone Asia/Bangkok not found in timedatectl list. Skipping."
  fi
}

install_basics() {
  begin_step "Install useful packages (ssh, ufw, curl, nc, sensors, tlp)"
  # openssh-server may already be installed
  run apt-get install -y \
    openssh-server ufw curl wget nano \
    net-tools iproute2 \
    netcat-openbsd \
    lm-sensors tlp

  # Optional: smartmontools for disk health
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

  # Ensure key settings exist (do not remove existing lines, just append with match guard)
  # PermitRootLogin no
  # PasswordAuthentication yes (keep enabled by default for new server; you can change later)
  # PubkeyAuthentication yes
  # UsePAM yes
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
  # Allow SSH before enabling ufw
  run ufw allow OpenSSH || true
  run ufw allow 22/tcp || true

  info "Set default policies: deny incoming, allow outgoing"
  run ufw default deny incoming
  run ufw default allow outgoing

  info "Enable ufw (non-interactive)"
  # If already enabled, this will still be ok
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
  begin_step "Configure lid close action to ignore (keep running when lid closed)"
  local cfg="/etc/systemd/logind.conf"
  info "Backing up ${cfg}"
  run cp -a "$cfg" "${cfg}.bak.$(date +%F-%H%M%S)" || true

  # Ensure settings under [Login]
  if grep -qE '^\[Login\]' "$cfg"; then
    :
  else
    echo "[Login]" >> "$cfg"
  fi

  # Replace existing or append
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

  info "Detect sensors (safe defaults). This may print prompts but usually works non-interactive."
  # sensors-detect may ask questions; use -y to auto-accept recommended options
  run sensors-detect --auto || true

  info "Current sensor readings"
  sensors || true

  ok "TLP and sensors ready."
}

set_static_ip_hint() {
  begin_step "Show current IP info (for router port forwarding)"
  info "Network interfaces"
  ip -br a || true
  echo
  info "Default route"
  ip route | sed -n '1,5p' || true
  echo
  info "Public IP (if accessible)"
  curl -s ifconfig.me || true
  echo
  ok "IP info printed."
}

final_checks() {
  begin_step "Final checks and summary"
  echo "Log file: $LOG_FILE"
  echo
  info "Check SSH listening ports"
  ss -lntp | grep -E '(:22[[:space:]]|sshd)' || true
  echo
  info "Check firewall rules"
  ufw status verbose || true
  echo
  info "Power management masks"
  systemctl list-unit-files | grep -E 'sleep.target|suspend.target|hibernate.target|hybrid-sleep.target' || true
  echo
  ok "Setup complete."

  echo
  echo "Next steps:"
  echo "1) Test SSH from another machine in LAN:"
  echo "   ssh <username>@<local_ip>"
  echo "2) If you want SSH via public IP on home Internet:"
  echo "   - Set port forwarding on router: external 22 -> internal <local_ip>:22"
  echo "   - If you are behind CGNAT, use Tailscale instead."
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
  set_static_ip_hint
  final_checks
}

main "$@"
