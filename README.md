# Server Setup Scripts

Collection of Ubuntu/Debian server setup automation scripts for 24/7 server deployments.

## 📦 Scripts Overview

### 1. **tui-server-setup.sh** (Recommended)
Interactive TUI (Text User Interface) with full feature set and dry-run mode.

**Features:**
- **Task Selection** — Pick only the tasks you need via checklist
- **USB Ethernet** — Auto-detect USB NIC, rename via udev, configure systemd-networkd with DHCP + route metrics
- **Dry-Run Mode** — Preview all changes without modifying the system
- **Progress Display** — Mixed gauge showing real-time task status (Pending / Running / Succeeded / Failed)
- **System Info Banner** — Displays OS, Kernel, CPU, and RAM right on the main menu
- **Post-Apply Summary** — Detailed report of all configured settings
- **Log Viewer** — Built-in log tail viewer
- **Custom Theme** — Dark cyan color scheme

### 2. **ubuntu-24x7-server-setup.sh**
Non-interactive script with all features enabled by default. Good for automated deployments.

### 3. **usbeth.sh**
Standalone USB Ethernet configuration script (can be used independently).

## 🚀 Quick Start

### Interactive TUI (Recommended)
```bash
sudo bash tui-server-setup.sh
```

### Non-Interactive (All Features)
```bash
sudo bash ubuntu-24x7-server-setup.sh
```

### USB Ethernet Only
```bash
# Edit USB_MAC variable first
sudo bash usbeth.sh
```

## 📋 Available Tasks

| # | Task | Description |
|---|------|-------------|
| 1 | Update/Upgrade | `apt-get update && upgrade && autoremove` |
| 2 | Auto Updates | Install unattended-upgrades for automatic security patches |
| 3 | Timezone | Set to `Asia/Bangkok` |
| 4 | Base Packages | openssh-server, ufw, curl, wget, nano, net-tools, lm-sensors, tlp, smartmontools, git, htop, tmux, ncdu, jq, unzip, rsync, iotop, zsh |
| 5 | ZSH + Oh-My-Zsh | Install ZSH shell with Oh-My-Zsh framework (ubuntu-24x7 only) |
| 6 | Lazydocker | Install Lazydocker TUI for Docker management (ubuntu-24x7 only) |
| 7 | SSH Hardening | PermitRootLogin=no, PasswordAuth=yes, PubkeyAuth=yes (drop-in config) |
| 8 | Fail2Ban | SSH protection (maxretry=5, bantime=10m, findtime=10m) |
| 9 | UFW Firewall | Allow SSH with rate limiting, deny incoming, allow outgoing |
| 10 | Passwordless Sudo | Allow `$SUDO_USER` to use `sudo` without password (TUI optional, not in ubuntu-24x7) |
| 11 | Docker Engine | Official Docker + Compose, add user to docker group |
| 12 | Disable Sleep | Mask sleep/suspend/hibernate/hybrid-sleep targets |
| 13 | Lid Close | HandleLidSwitch=ignore (drop-in config) |
| 14 | TLP + Sensors | Enable TLP power management, auto-detect sensors |
| 15 | Wait-Online | Disable systemd-networkd-wait-online for faster boot |
| 16 | Tailscale VPN | Install Tailscale, add user to tailscale group |
| 17 | USB Ethernet | Auto-detect, rename, DHCP with route metrics, disable cloud-init network |

## 🔒 Security Features

- **SSH Hardening**: Drop-in config at `/etc/ssh/sshd_config.d/99-harden.conf`
  - ✅ PasswordAuthentication YES (safe - prevents lockout)
  - ✅ PubkeyAuthentication YES (allows SSH keys)
  - ❌ PermitRootLogin NO (blocks root login)
- **Fail2Ban**: Automatic SSH brute-force protection
- **UFW**: Rate-limited SSH (prevents rapid connection attempts)
- **Auto Updates**: Daily security patches via unattended-upgrades

## 📖 TUI Menu Layout (tui-server-setup.sh)

```
1. Configure -- choose tasks     (checklist toggle)
2. USB Ethernet -- configure     (submenu with interface, metrics, cloud-init)
3. Show plan                     (review before applying)
4. Apply selected tasks          (execute with progress display)
5. Dry-run mode [OFF]            (toggle: preview without changes)
6. Tail log                      (view log in real-time)
7. Exit
```

## 📝 Logging

All actions are logged to `/var/log/24x7-setup/`:
- **TUI**: `tui-setup-<timestamp>.log`
- **ubuntu-24x7**: `setup-<timestamp>.log`

Logs include:
- Commands executed and their output
- Files written/backed up
- Errors and warnings

## 🧪 Dry-Run Mode (TUI only)

Toggle from the main menu (option 5). When enabled:
- Commands are logged but **not executed**
- Files are logged but **not written**
- Backups are logged but **not created**
- Useful for testing on production servers

## 🐳 Docker Engine

Installs Docker natively from the official `download.docker.com` repository (avoids the Ubuntu snap version). 

**Automatic extras:**
- Installs `docker-compose-plugin`
- Adds the invoking user (`$SUDO_USER`) to the `docker` group (no `sudo` needed for docker commands)

**Post-install:**
```bash
# Logout/login for group to take effect
docker --version
docker compose version
```

## 🛡️ Fail2Ban

Provides brute-force protection for SSH. Automatically configures `/etc/fail2ban/jail.local`:
- **Max retry**: 5 attempts
- **Ban time**: 10 minutes
- **Find time**: 10 minutes

## 🔄 Auto Security Updates

Installs and enables `unattended-upgrades` to automatically download and apply security patches daily without manual intervention.

## 🌐 Tailscale VPN

Installs [Tailscale](https://tailscale.com/) via the official install script.

**Extras:**
- Adds the invoking user (`$SUDO_USER`) to the `tailscale` group

**Post-install:**
```bash
# Authenticate and connect to your tailnet
tailscale up

# Check status
tailscale status
```

## 🔌 USB Ethernet Setup

Automatically detects USB NICs and configures:
- **udev rule** — Rename interface (default: `usbeth0`)
- **systemd-networkd** — DHCP with custom route metrics
- **WiFi deprioritization** — Higher metric for WiFi interfaces
- **Cloud-init** — Optionally disables cloud-init network config

**Default metrics:** USB=10 (preferred), WiFi=600 (fallback)

## ⚙️ Requirements

- Ubuntu/Debian-based system
- Root privileges (`sudo`)
- `dialog` (auto-installed if missing for TUI)
- Internet connection

## 📌 Notes

- **ubuntu-24x7-server-setup.sh**: Runs all tasks automatically (no passwordless sudo)
- **tui-server-setup.sh**: Interactive menu, choose what you need (passwordless sudo optional)
- **usbeth.sh**: Standalone USB Ethernet setup (edit `USB_MAC` variable before running)
- All scripts use drop-in configs (best practice) instead of sed modifications
- SSH password authentication is kept enabled for safety (prevents lockout)

## 📄 License

MIT
