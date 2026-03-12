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
  begin_step "Install useful packages (ssh, ufw, curl, nc, sensors, tlp, git, htop, etc.)"
  # openssh-server may already be installed
  run apt-get install -y \
    openssh-server ufw curl wget nano \
    net-tools iproute2 \
    netcat-openbsd \
    lm-sensors tlp \
    git htop tmux ncdu jq unzip rsync iotop zsh

  # Optional: smartmontools for disk health
  run apt-get install -y smartmontools || true

  ok "Installed packages."
}

install_zsh() {
  begin_step "Install ZSH + Oh My Zsh"
  
  # For root
  if [[ ! -d /root/.oh-my-zsh ]]; then
    info "Installing Oh My Zsh for root..."
    wget -O/tmp/install_omz.sh https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh 2>&1 | tee -a "$LOG_FILE"
    sh /tmp/install_omz.sh --unattended 2>&1 | tee -a "$LOG_FILE"
    rm -f /tmp/install_omz.sh
    run chsh -s "$(which zsh)" root
  else
    info "Oh My Zsh already installed for root"
  fi
  
  # For primary user
  if [[ -n "${PRIMARY_USER}" ]]; then
    local user_home
    user_home="$(eval echo "~${PRIMARY_USER}")"
    if [[ ! -d "$user_home/.oh-my-zsh" ]]; then
      info "Installing Oh My Zsh for ${PRIMARY_USER}..."
      su - "${PRIMARY_USER}" -c 'wget -O/tmp/install_omz_user.sh https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh' 2>&1 | tee -a "$LOG_FILE"
      su - "${PRIMARY_USER}" -c 'sh /tmp/install_omz_user.sh --unattended' 2>&1 | tee -a "$LOG_FILE"
      rm -f /tmp/install_omz_user.sh
      run chsh -s "$(which zsh)" "${PRIMARY_USER}"
    else
      info "Oh My Zsh already installed for ${PRIMARY_USER}"
    fi
  fi
  
  ok "ZSH + Oh My Zsh installed"
}

install_lazydocker() {
  begin_step "Install Lazydocker"
  if command -v lazydocker >/dev/null 2>&1; then
    info "Lazydocker already installed"
    return 0
  fi
  
  info "Downloading and installing Lazydocker..."
  curl https://raw.githubusercontent.com/jesseduffield/lazydocker/master/scripts/install_update_linux.sh | bash 2>&1 | tee -a "$LOG_FILE"
  
  if [[ -f "$HOME/.local/bin/lazydocker" ]]; then
    run install -m 0755 "$HOME/.local/bin/lazydocker" /usr/local/bin/lazydocker
  fi
  
  ok "Lazydocker installed"
}

configure_ssh() {
  begin_step "Enable and harden SSH (drop-in config)"
  run systemctl enable ssh
  run systemctl start ssh

  local dropin_dir="/etc/ssh/sshd_config.d"
  local dropin_file="${dropin_dir}/99-harden.conf"
  
  info "Creating SSH drop-in config"
  run mkdir -p "$dropin_dir"
  
  cat > "$dropin_file" <<'EOF'
# SSH Hardening - Keep password auth enabled for safety
PermitRootLogin no
PasswordAuthentication yes
PubkeyAuthentication yes
EOF
  
  info "Validate SSH config"
  run sshd -t

  run systemctl restart ssh
  run systemctl --no-pager -l status ssh
  ok "SSH configured (password auth ENABLED for safety)"
}

configure_firewall() {
  begin_step "Configure UFW firewall (allow SSH with rate limit, enable firewall)"
  # Allow SSH with rate limiting before enabling ufw
  run ufw limit OpenSSH || true
  run ufw limit 22/tcp || true

  info "Set default policies: deny incoming, allow outgoing"
  run ufw default deny incoming
  run ufw default allow outgoing

  info "Enable ufw (non-interactive)"
  # If already enabled, this will still be ok
  run ufw --force enable
  run ufw status verbose
  ok "Firewall configured."
}

configure_fail2ban() {
  begin_step "Install and configure Fail2Ban (SSH protection)"
  run apt-get install -y fail2ban
  
  local jail="/etc/fail2ban/jail.local"
  info "Creating Fail2Ban jail config"
  
  cat > "$jail" <<'EOF'
[DEFAULT]
bantime = 10m
findtime = 10m
maxretry = 5

[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
EOF
  
  run systemctl enable --now fail2ban
  run systemctl restart fail2ban
  run systemctl --no-pager -l status fail2ban
  ok "Fail2Ban configured (maxretry=5, bantime=10m)"
}

enable_auto_updates() {
  begin_step "Enable automatic security updates"
  run apt-get install -y unattended-upgrades update-notifier-common
  
  info "Configure unattended-upgrades"
  echo 'unattended-upgrades unattended-upgrades/enable_auto_updates boolean true' | debconf-set-selections 2>&1 | tee -a "$LOG_FILE"
  run dpkg-reconfigure -f noninteractive unattended-upgrades
  run systemctl enable --now unattended-upgrades
  run systemctl --no-pager -l status unattended-upgrades
  ok "Auto security updates enabled"
}

disable_sleep_suspend() {
  begin_step "Disable sleep, suspend, hibernate targets"
  run systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
  ok "Sleep targets masked."
}

ignore_lid_close() {
  begin_step "Configure lid close action to ignore (drop-in config)"
  local dropin_dir="/etc/systemd/logind.conf.d"
  local dropin_file="${dropin_dir}/99-ignore-lid.conf"
  
  info "Creating logind drop-in config"
  run mkdir -p "$dropin_dir"
  
  cat > "$dropin_file" <<'EOF'
[Login]
HandleLidSwitch=ignore
HandleLidSwitchDocked=ignore
EOF
  
  run systemctl restart systemd-logind
  run systemctl --no-pager -l status systemd-logind
  ok "Lid close behavior configured (drop-in)"
}

disable_wait_online() {
  begin_step "Disable systemd-networkd-wait-online (faster boot)"
  run systemctl disable --now systemd-networkd-wait-online.service || true
  run systemctl mask systemd-networkd-wait-online.service || true
  ok "Wait-online disabled"
}

install_docker() {
  begin_step "Install Docker Engine + Compose"
  if command -v docker >/dev/null 2>&1; then
    info "Docker already installed"
    docker --version 2>&1 | tee -a "$LOG_FILE"
    return 0
  fi
  
  info "Installing Docker from official repository..."
  run apt-get install -y ca-certificates curl gnupg
  run install -m 0755 -d /etc/apt/keyrings
  
  info "Adding Docker GPG key"
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg --yes 2>&1 | tee -a "$LOG_FILE"
  run chmod a+r /etc/apt/keyrings/docker.gpg
  
  info "Adding Docker repository"
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
  
  run apt-get update
  run apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  
  # Add primary user to docker group
  if [[ -n "${PRIMARY_USER}" ]]; then
    run usermod -aG docker "${PRIMARY_USER}"
    ok "Added ${PRIMARY_USER} to docker group"
    warn "User needs to logout/login for docker group to take effect"
  fi
  
  run systemctl enable --now docker
  run systemctl --no-pager -l status docker
  docker --version 2>&1 | tee -a "$LOG_FILE"
  docker compose version 2>&1 | tee -a "$LOG_FILE"
  ok "Docker installed"
}

install_tailscale() {
  begin_step "Install Tailscale VPN (optional)"
  if command -v tailscale >/dev/null 2>&1; then
    info "Tailscale already installed"
    tailscale version 2>&1 | tee -a "$LOG_FILE" || true
    return 0
  fi
  
  info "Installing Tailscale via official script..."
  curl -fsSL https://tailscale.com/install.sh | bash 2>&1 | tee -a "$LOG_FILE"
  run systemctl enable --now tailscaled
  
  # Add primary user to tailscale group
  if [[ -n "${PRIMARY_USER}" ]]; then
    run usermod -aG tailscale "${PRIMARY_USER}" || true
    ok "Added ${PRIMARY_USER} to tailscale group"
  fi
  
  info "Run 'tailscale up' to authenticate and connect"
  ok "Tailscale installed"
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
  install_zsh
  install_lazydocker
  configure_ssh
  configure_fail2ban
  configure_firewall
  enable_auto_updates
  disable_sleep_suspend
  ignore_lid_close
  enable_tlp_sensors
  disable_wait_online
  install_docker
  install_tailscale
  set_static_ip_hint
  final_checks
}

main "$@"
