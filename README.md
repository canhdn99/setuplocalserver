# Server Setup TUI

Interactive TUI (Text User Interface) for automated Ubuntu/Debian server setup, built with `dialog`.

## Features

- **Task Selection** — Pick only the tasks you need via checklist
- **USB Ethernet** — Auto-detect USB NIC, rename via udev, configure systemd-networkd with DHCP + route metrics
- **Dry-Run Mode** — Preview all changes without modifying the system
- **Progress Display** — Mixed gauge showing real-time task status (Pending / Running / Succeeded / Failed)
- **System Info Banner** — Displays OS, Kernel, CPU, and RAM right on the main menu
- **Post-Apply Summary** — Detailed report of all configured settings
- **Log Viewer** — Built-in log tail viewer
- **Custom Theme** — Dark cyan color scheme

## Available Tasks

| # | Task | Description |
|---|------|-------------|
| 1 | Update/Upgrade | `apt-get update && upgrade && autoremove` |
| 2 | Auto Updates | Install unattended-upgrades for automatic daily security patches |
| 3 | Timezone | Set to `Asia/Bangkok` |
| 4 | Base Packages | openssh-server, ufw, curl, wget, nano, net-tools, lm-sensors, tlp, smartmontools |
| 5 | SSH Hardening | PermitRootLogin=no, PasswordAuth=yes, PubkeyAuth=yes (via drop-in conf) |
| 5 | Fail2Ban | Install and configure local jail for SSH protection |
| 6 | UFW Firewall | Allow SSH, deny incoming, allow outgoing |
| 7 | Docker | Install Docker Engine (official apt), Compose, add user to docker group |
| 8 | Disable Sleep | Mask sleep/suspend/hibernate/hybrid-sleep targets |
| 10 | Lid Close | HandleLidSwitch=ignore, HandleLidSwitchDocked=ignore (via drop-in conf) |
| 11 | TLP + Sensors | Enable TLP power management, auto-detect sensors |
| 12 | Wait-Online | Disable systemd-networkd-wait-online for faster boot |
| 13 | Tailscale VPN | Install Tailscale via official script, enable tailscaled |
| 14 | USB Ethernet | Auto-detect, rename, DHCP with route metrics, disable cloud-init network |

## Quick Start

```bash
# Basic usage
sudo bash tui-server-setup.sh

# The TUI menu will appear — select tasks, configure, then apply
```

## Requirements

- Ubuntu/Debian-based system
- Root privileges (`sudo`)
- `dialog` (auto-installed if missing)

## Menu Layout

```
1. Configure -- choose tasks     (checklist toggle)
2. USB Ethernet -- configure     (submenu with interface, metrics, cloud-init)
3. Show plan                     (review before applying)
4. Apply selected tasks          (execute with progress display)
5. Dry-run mode [OFF]            (toggle: preview without changes)
6. Tail log                      (view log in real-time)
7. Exit
```

## Logging

All actions are logged to `/var/log/24x7-setup/tui-setup-<timestamp>.log`.

Logs include:
- Commands executed and their output
- Files written/backed up
- Errors and warnings

## Dry-Run Mode

Toggle from the main menu (option 5). When enabled:
- Commands are logged but **not executed**
- Files are logged but **not written**
- Backups are logged but **not created**
- Useful for testing on production servers

## Docker Engine

Installs Docker natively from the official `download.docker.com` repository (avoids the Ubuntu snap version). Automatic extras:
- Installs `docker-compose-plugin`
- Adds the invoking user (`$SUDO_USER`) to the `docker` group so you don't need `sudo` to run containers.

## Fail2Ban

Provides brute-force protection for your SSH port. Automatically configures a `jail.local` with:
- Max retry: 3 attempts
- Ban time: 1 hour

## Auto Security Updates

Installs and enables `unattended-upgrades` non-interactively to ensure the server automatically downloads and applies essential security patches daily without manual intervention.

## Tailscale VPN

Installs [Tailscale](https://tailscale.com/) via the official install script. After apply:

```bash
# Authenticate and connect to your tailnet
sudo tailscale up

# Check status
tailscale status
```

## USB Ethernet Setup

Automatically detects USB NICs and configures:
- **udev rule** — Rename interface (default: `usbeth0`)
- **systemd-networkd** — DHCP with custom route metrics
- **WiFi deprioritization** — Higher metric for WiFi interfaces
- **Cloud-init** — Optionally disables cloud-init network config

Default metrics: USB=10 (preferred), WiFi=600 (fallback).

## License

MIT
