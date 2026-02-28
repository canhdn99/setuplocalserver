# Server Setup TUI

Interactive TUI (Text User Interface) for automated Ubuntu/Debian server setup, built with `dialog`.

## Features

- **Task Selection** — Pick only the tasks you need via checklist
- **USB Ethernet** — Auto-detect USB NIC, rename via udev, configure systemd-networkd with DHCP + route metrics
- **Dry-Run Mode** — Preview all changes without modifying the system
- **Progress Display** — Mixed gauge showing real-time task status (Pending / Running / Succeeded / Failed)
- **Post-Apply Summary** — Detailed report of all configured settings
- **Log Viewer** — Built-in log tail viewer
- **Custom Theme** — Dark cyan color scheme

## Available Tasks

| # | Task | Description |
|---|------|-------------|
| 1 | Update/Upgrade | `apt-get update && upgrade && autoremove` |
| 2 | Timezone | Set to `Asia/Bangkok` |
| 3 | Base Packages | openssh-server, ufw, curl, wget, nano, net-tools, lm-sensors, tlp, smartmontools |
| 4 | SSH Hardening | PermitRootLogin=no, PasswordAuth=yes, PubkeyAuth=yes |
| 5 | UFW Firewall | Allow SSH, deny incoming, allow outgoing |
| 6 | Disable Sleep | Mask sleep/suspend/hibernate/hybrid-sleep targets |
| 7 | Lid Close | HandleLidSwitch=ignore, HandleLidSwitchDocked=ignore |
| 8 | TLP + Sensors | Enable TLP power management, auto-detect sensors |
| 9 | Wait-Online | Disable systemd-networkd-wait-online for faster boot |
| 10 | USB Ethernet | Auto-detect, rename, DHCP with route metrics, disable cloud-init network |

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

## USB Ethernet Setup

Automatically detects USB NICs and configures:
- **udev rule** — Rename interface (default: `usbeth0`)
- **systemd-networkd** — DHCP with custom route metrics
- **WiFi deprioritization** — Higher metric for WiFi interfaces
- **Cloud-init** — Optionally disables cloud-init network config

Default metrics: USB=10 (preferred), WiFi=600 (fallback).

## License

MIT
