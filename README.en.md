<div align="center">

# 🚀 XKIT

**Your turnkey VPN server: 3X-UI panel behind nginx, all protocols, one subscription per user — managed from Telegram.**

![Version](https://img.shields.io/badge/version-9.2.1-blue?style=flat-square)
![Platform](https://img.shields.io/badge/platform-Ubuntu%2024.04%2B-orange?style=flat-square)
![Shell](https://img.shields.io/badge/core-Bash-4EAA25?style=flat-square&logo=gnubash&logoColor=white)
![TUI](https://img.shields.io/badge/TUI-Go%20%2B%20Bubble%20Tea-00ADD8?style=flat-square&logo=go&logoColor=white)
![Architecture](https://img.shields.io/badge/linux-amd64%20%C2%B7%20arm64-lightgrey?style=flat-square)
![License](https://img.shields.io/badge/license-MIT-green?style=flat-square)

[🇷🇺 Русский](README.md) · [🇬🇧 English](README.en.md)

One-command install · TUI & menu · REALITY / XHTTP / AmneziaWG / Hysteria 2 · Telegram admin bot · Cascade via foreign nodes · Backups & migration

[Install](#-quick-start) · [Telegram bot](#-telegram-bot--manage-from-your-phone) · [Protocols](#-protocols) · [Nodes & cascade](#-nodes--cascade) · [Commands](#-cli-commands) · [FAQ](#-faq)

</div>

---

> ⚠️ **Disclaimer**
>
> XKIT is created **for educational and research purposes only** — to study nginx, Xray, TLS and network protocols on your own hardware. Everything you do with this tool is at your own risk, and you are solely responsible for compliance with the laws of your country and the rules of your hosting provider. If using such tooling is restricted in your jurisdiction, do not use this project. The authors accept no liability for any consequences of its use.

---

## 🎯 What is it

**XKIT** turns a fresh VPS (Ubuntu 24.04+) into a ready VPN server and handles all the maintenance:

- installs the **3X-UI + Xray** panel and hides it behind **nginx** — the panel is not exposed; a "random" visitor sees an ordinary website;
- sets up a **certificate** (domain, IP or self-signed) and keeps it renewed;
- creates **protocols**: VLESS REALITY, VLESS XHTTP, AmneziaWG, Hysteria 2;
- **one user = all protocols = one subscription** with a shared quota and expiry;
- manage everything via **TUI**, classic menu, CLI or a **Telegram bot from your phone**;
- connects **foreign nodes** and balances traffic: client → your server → cascade → the world;
- makes **backups**, migrates the server to a new machine, self-updates — signed releases only.

## 💡 Philosophy

- **Only what's needed faces the internet.** The panel listens on `127.0.0.1`; only client entry points and the cover site are public.
- **One user — one subscription.** Add a person — they're instantly in every protocol. Add a protocol — "Refresh subscriptions" and everyone gets it. No manual syncing.
- **Don't trust — verify.** Every component is installed only after SHA-256 and release-signature checks. Mismatch means the install stops, not "continues at your own risk".
- **Error = rollback.** nginx config is tested before applying; core updates roll back automatically if the panel fails to come up. A mandatory backup precedes any removal.
- **We don't touch what isn't ours.** XKIT never silently enables your firewall, never deletes foreign rules or sites, never runs `apt upgrade` for you.
- **Secrets don't leak.** Passwords and keys live in `600` files, travel via stdin, never appear in logs; QR codes and subscriptions are generated locally, no external services.
- **Automation with human veto.** Dangerous operations require confirmation; expiry reminders, alerts and checks run themselves, but reboots and deletions are your call.

---

## ⚡ Quick start

### Requirements

- VPS with **Ubuntu 24.04+**, `root` SSH access;
- `amd64` or `arm64` architecture;
- a domain is **optional** — domain, IP and self-signed certificates all work.

### Install

```bash
curl -fsSL https://raw.githubusercontent.com/kambarro/xkit/main/install.sh | sudo bash
```

The installer asks the essentials, sets up the panel, certificate and cover site, offers protocol selection and immediately tells you how to add users. At the end you get the panel address, credentials (in `/root/xkit-info.txt`) and subscriptions.

Unattended: append `-s -- -y` (over an existing install: `--force`).

### Migrating from a backup

Put an `xkit-*.tar.gz` archive into `/root/xkit-restore/` and run the installer — it offers a full or partial restore (certificates, users & panel, nodes). Nodes reconnect on their own; clients keep their subscriptions.

### Run

```bash
sudo xkit             # fullscreen TUI
sudo xkit --classic   # classic text menu
```

### Update

```bash
sudo xkit update
```

State, users and subscriptions are preserved. After updating from the TUI, the interface offers to restart itself ("press Enter") so the new menu loads immediately. Check for a new version without installing: `xkit update --check`.

### Uninstall

```bash
sudo xkit uninstall          # xkit + its nginx site; a backup is mandatory
sudo xkit uninstall --full   # + 3X-UI panel and xkit certificates
sudo xkit uninstall --purge  # everything, NO backup (confirm: PURGE)
```

Your SSH and access firewall rules are never touched; foreign sites and certificates are preserved (except with `--purge`).

---

## 🖥️ Interfaces

### TUI

Fullscreen interface: service status, users, protocols, nodes, maintenance. Navigation:

| Key | Action |
|---|---|
| `↑` `↓` / `j` `k` | move |
| `Enter` | open / run |
| `Esc` / `q` | back; on the main screen — quit |
| `/` | search in section |
| `r` | refresh status |
| `?` | help |

Russian-layout keys work too (`о`/`л`/`й`/`к`). Command output stays on screen until `Enter`. After `xkit update` the TUI offers to restart the interface to pick up the new version and menu.

### Classic menu

`xkit --classic` — the same thing with numbers, for those who prefer it and for non-TTY scenarios (cron, pipes). Six groups: install, users, protocols, nodes, maintenance, monitoring.

### Telegram bot — manage from your phone

A full admin interface in Telegram:

```bash
sudo xkit telegram setup    # bot token + your chat + admin IDs
sudo xkit telegram bot on   # enable the bot service
```

Open the bot, send `/start` — an inline-button menu appears:

- **👥 Users** — create, list, subscription & QR, reset traffic, disable/enable, delete (with confirmation);
- **🖥 Nodes** — status, metrics, checks, channel profile switching, maintenance;
- **⏰ Lease expiry** — master and node deadlines, reminders at 7/3/1 days (once a day, no spam);
- **📊 Status** — services, certificate, disk, a short summary;
- **🛠 Maintenance** — health check, backup, XKIT update, restart the whole stack (3X-UI/Xray/nginx), server reboot — dangerous actions only via "✅ Yes";
- **🔀 TG transport** — delivery channel status.

**The bot works even where Telegram is blocked:** if direct access to the Telegram API is unavailable, messages travel through an SSH tunnel to a foreign node. Channels are re-checked and self-heal (~every 20 seconds); if all are down, the bot patiently waits for any to come back. After a server reboot the bot messages you that the master is back online.

Access is limited to the configured admin IDs; everyone else gets silence. All actions are audit-logged.

---

## 🛡️ Protocols

Menu: `xkit protocols` (or TUI → "Protocols").

| Protocol | What it is | When to choose |
|---|---|---|
| **VLESS + REALITY + Vision** | main TCP profile, mimics a foreign TLS site | the default; works for most |
| **VLESS + XHTTP + REALITY** | alternative transport | when plain REALITY gets squeezed |
| **AmneziaWG** | obfuscated WireGuard (3.1 Header Protection or classic profile) | UDP where TCP is throttled; routers, AmneziaVPN |
| **Hysteria 2** | fast UDP/QUIC with Salamander obfuscation | lossy links, mobile networks |

Good to know:

- **A user is created in all protocols at once** — one subscription for everything;
- **Disable ≠ delete**: a protocol can be switched off (like the panel toggle) — it disappears from subscriptions but stays in the panel; switch it back on and it returns. Same for users;
- **Added a protocol later?** "Refresh subscriptions" (`xkit client bind`) attaches it to every existing user;
- the REALITY wizard scans and offers suitable cover sites (your own site, subnet scan, a curated list, or manual);
- XKIT never silently enables your UFW: it adds the needed allow rules first; enabling is only with your consent.

> A local "running" status does not guarantee reachability for a specific client ISP — that depends on the network, region and IP reputation. Verify with a real connection.

### Subscriptions

Every user gets:

- a **subscription page** — open in a browser: QR, links, one-click import;
- a **direct link** for v2rayNG / Streisand / Hiddify / v2rayN (base64);
- **`.yaml`** for Clash Verge / FlClash (Mihomo) — with split routing: RU sites direct, the rest via proxy;
- **`.json`** for sing-box;
- **`/amnezia`** — a page with QR and config for AmneziaVPN.

View: `xkit client show NAME` or bot → Users → 🔗 Subscription. QR codes are generated locally.

---

## 🌍 Modes

**Single server** — everything on one machine:

```text
client → your server (nginx / REALITY / UDP protocols) → internet
```

**Master with nodes** — your server in a restricted region + foreign nodes:

```text
client → master → cascade (balancing) → node 1 / node 2 → internet
```

### Nodes & cascade

- add a node over SSH: `xkit nodes` — XKIT installs the panel on the node, builds a secure tunnel and configures balancing;
- balancing strategies: `roundRobin`, `random`, `leastPing`, `leastLoad`;
- **channel profiles** master→node: VLESS TCP REALITY, XHTTP REALITY, Hysteria 2 — switching with a real speed test and rollback on failure (`xkit nodes profile switch`);
- **change a node's IP** without reinstalling (`xkit nodes readdress`);
- monitoring: traffic, speed, ping, CPU/RAM per node — in the TUI and the bot;
- TCP "freeze" detection (`xkit nodes freeze`) — tells you if the ISP throttles TCP on the foreign leg;
- removing the last node returns the server to single mode.

Per-node credentials live in `/root/xkit-node-NAME.txt` (mode 600).

---

## 🧰 Maintenance

| Task | How |
|---|---|
| Check the server | `xkit health` (deep: `xkit health deep` — a real client probe) |
| Backup | `xkit backup` (daily automatic; verify: `xkit backup verify`) |
| Restore | `xkit restore` (`--dry-run` first if you like) |
| Restart everything | `xkit services restart` (3X-UI/Xray/nginx; the bot sends a check) |
| Reissue certificate | "Maintenance" menu or the bot |
| Panel/core versions | `xkit versions list / install / rollback` — verified releases only, SHA-256 + auto-rollback |
| Cover site | `xkit camo status / regenerate` — a unique seed-based site, no external CDNs |
| Lease expiry | `xkit expiry set / list` — Telegram reminders |
| Action log | `xkit audit` |
| Diagnostic bundle | `xkit doctor export` — secrets stripped, safe to share |

---

## 🖥️ CLI commands

Full list: `xkit help`. The essentials:

```bash
xkit                              # TUI
xkit --classic                    # classic menu
xkit update [--check]             # update / check version
xkit install | reinstall | uninstall [--full|--purge]

# users
xkit client add                   # create (in all protocols)
xkit client list                  # list
xkit client show EMAIL            # links + QR
xkit client bind                  # bind everyone to every protocol + rebuild subscriptions
xkit client disable|enable EMAIL  # disable/enable a user (everywhere at once)
xkit client reset EMAIL --yes     # reset traffic
xkit client del EMAIL --yes       # delete
xkit sub                          # rebuild subscription files
xkit sub qr SUBID                 # local QR

# protocols
xkit protocols                    # menu
xkit protocols list [--json]      # summary (including disabled)
xkit protocols toggle             # disable/enable a protocol (stays in the panel)
xkit protocols xhttp|awg|hysteria2  # protocol wizards
xkit reality                      # REALITY wizard

# nodes
xkit nodes                        # nodes menu
xkit nodes check all [--deep]     # checks
xkit nodes metrics                # refresh metrics
xkit nodes profile list|switch|benchmark  # master→node channel
xkit nodes readdress NAME IP      # change IP
xkit nodes freeze NAME            # TCP freeze measurement
xkit nodes repair|repin|relogin   # maintenance

# Testing the SERVER itself (not the VPN tunnel) — directly on master or a node
xkit test bench [master|NAME]     # VPS passport: system, disk, raw channel speed (~6 GB load)
xkit test ipregion [master|NAME]  # how ~45 services see this IP's country (exposes the IP)
xkit test freeze [NAME|all]       # TSPU freeze measurement (alias of nodes freeze)
# results: /var/lib/xkit/test-results/; in TUI/bot — "Server testing" section

# Telegram
xkit telegram setup|check|test    # notifications setup & check
xkit telegram bot on|off|status   # admin bot
xkit telegram transport list|check  # delivery channels via nodes

# maintenance
xkit health [deep]                # diagnostics
xkit services restart             # restart the whole stack
xkit backup | restore             # backup / restore
xkit versions list|install|rollback
xkit expiry set|list|check
xkit camo status|regenerate
xkit audit | doctor export | info | status
```

---

## 🗺️ Command map: where each command lives

No need to type commands by hand — almost everything is in the TUI (`xkit`),
the classic menu (`xkit --classic`) and the Telegram bot. ✅ = a menu item /
button exists, — = CLI only. Rare service commands are intentionally CLI-only.

| Command | Purpose | TUI | Menu | Bot |
|---|---|---|---|---|
| `client add / list / show / del / reset / bind / toggle` | Users: create, list, links, delete, reset, bind, enable/disable | ✅ | ✅ | ✅ |
| `sub / sub qr` | Subscriptions: rebuild, QR (SVG/PNG/Amnezia) | ✅ | ✅ | ✅ |
| `reality / reality scan / scan-csv` | REALITY: wizard, decoy-site scan, CSV report | ✅ | ✅ | — |
| `protocols xhttp / ws / awg / hy2 / panel` | Protocol wizards | ✅ | ✅ | — |
| `protocols list / toggle / remove / ports` | Protocols: summary, toggle, remove, ports | ✅ | ✅ | — |
| `nodes / nodes add / list / del / health / strategy` | Nodes: add, list, delete, health, balancing | ✅ | ✅ | — |
| `nodes check / metrics` | Nodes: SSH/API/resource check, metrics | ✅ | ✅ | — |
| `nodes repair / repin / relogin / panel-sync / token` | Nodes: repair, cert trust, tokens, 3X-UI "Nodes" | ✅ | ✅ | — |
| `nodes plan / apply` | Nodes: drift plan, canary apply | — | ✅ | — |
| `nodes cert / cert-renew / hide / ufw` | Nodes: certs, renewal, panel hiding, firewall | ✅ | ✅ | ✅ |
| `nodes camo / camo-off` | Nodes: camo site | ✅ | ✅ | ✅ |
| `nodes versions / upgrade / latest` | Nodes: 3X-UI/Xray versions, upgrade | ✅ | ✅ | ✅ |
| `nodes profile / tune / readdress` | Nodes: transport profile, TCP tuning, IP change | ✅ | ✅ | ✅ |
| `nodes freeze (alias of test freeze)` | TSPU "freeze" measurement | ✅ | ✅ | ✅ |
| `nodes pool-link / credentials` | Cascade pool link, node credentials to file | ✅* | — | — |
| `health / health deep / status` | Diagnostics: services, ports, client test | ✅ | ✅ | ✅ |
| `test bench / ipregion / freeze` | Server benchmark (not the tunnel) | ✅ | ✅ | ✅ |
| `backup / backup settings / restore` | Backups: create, schedule, restore | ✅ | ✅ | ✅ |
| `versions list / install / latest / rollback` | 3X-UI + Xray version pairs | ✅ | ✅ | — |
| `update / update --check` | xkit self-update | ✅ | ✅ | ✅ |
| `camo status / files / regenerate` | Master camo site | ✅ | ✅ | — |
| `route / extfix` | nginx routing / panel link fix | ✅ | ✅ | — |
| `sockopt / bbr` | TCP Fast Open / BBR+fq | ✅ | ✅ | — |
| `services restart / reboot` | Stack / server restart | ✅ | ✅ | ✅ |
| `restart defer / apply / status` | Deferred restarts | ✅ | ✅ | — |
| `expiry set / list / check / del` | Server rental expiry | ✅ | ✅ | ✅ |
| `telegram setup / bot / transport / check / off` | Control bot, alerts, transports | ✅ | ✅ | ✅ |
| `telegram-proxy mtproto / web / list / link` | Telegram proxies for clients | ✅ | ✅ | — |
| `ledger collect / show / quota-check` | Monotonic traffic ledger | ✅ | ✅ | — |
| `audit / doctor export / info` | Audit log, support bundle, credentials | ✅ | ✅ | — |
| `maintenance install / run` | Logrotate + daily timer | ✅ | ✅ | — |
| `geodata update / auto / timer` | Geo files with SHA pins (CLI only) | — | — | — |
| `core-pin [версия]` | Pin Xray core (CLI only) | — | — | — |
| `install / reinstall / uninstall` | Install / reinstall / uninstall | — | ✅ | — |

*TUI has credentials only; pool-link is CLI-only (technical cascade link).

Full syntax of every command: `xkit help`.

---

## 🔒 Security in brief

- components and updates install only after **SHA-256 + Ed25519 release signature** checks; mismatch = refusal;
- panel on `127.0.0.1` with a secret path; nginx and the cover site face the internet;
- passwords/keys in `600` files, passed via stdin, masked in logs and snapshots;
- SSH to nodes verifies host keys; panel API uses pinned TLS;
- `nginx -t` and a backup before changes, auto-rollback on error;
- removal requires confirmation and a mandatory backup (except explicit `--purge`);
- the bot answers only its admin IDs; dangerous actions go through confirmation.

---

## 🗂️ Where things live

```text
/usr/local/bin/xkit               # the command
/usr/local/lib/xkit/              # menu, protocols, TUI
/etc/xkit/                        # settings and state
/var/lib/xkit/subs/               # subscription files
/var/backups/xkit/                # backups
/var/log/xkit-*.log               # logs
/root/xkit-info.txt               # credentials (600)
/root/xkit-node-NAME.txt          # node credentials (600)
```

---

## ❓ FAQ

**Do I need a domain?** No, IP works. But a domain makes the camouflage more natural.

**Can I install over an existing 3X-UI?** Yes — XKIT picks up the panel and hides it behind nginx.

**update vs reinstall?** `update` preserves all state; `reinstall` backs up and installs from scratch.

**Updated from the TUI but the menu is old?** Since 8.2.0 the TUI offers a restart after updating. On older versions, quit and run `xkit` again.

**Telegram is blocked on the server — will the bot work?** Yes, via an SSH tunnel to a foreign node. At least one node is required; channels self-heal.

**A client can't connect — what now?** `xkit health deep` probes the server as a real client. If the server is fine, it's the client's network/ISP: try another protocol (UDP options often survive where TCP is throttled).

**Does XKIT guarantee bypassing censorship?** No. The tool configures a server; reachability depends on network, region and timing. No guarantees.

---

## 🛠️ Troubleshooting

```bash
sudo xkit health                  # general diagnostics
sudo systemctl status nginx x-ui  # services
sudo nginx -t                     # nginx config
sudo ls -lt /var/log/xkit-*.log   # logs
sudo xkit telegram check          # alerts not arriving?
sudo xkit doctor export           # bundle for analysis (no secrets)
```

**Never bypass** a SHA-256 mismatch during install — make sure all files come from the same release.

---

## 🙏 Credits & upstream projects

XKIT stands on the shoulders of these projects — thank you to their authors:

- 💡 **[3X-UI KIT](https://github.com/itsnotkubrick/3X-UI_KIT)** (itsnotkubrick) — the inspiring idea: "fresh VPS → ready VPN with one command, one subscription for everything". XKIT extends it towards cascades, Telegram management and a TUI;
- **[3X-UI](https://github.com/MHSanaei/3x-ui)** (MHSanaei) — the Xray management panel at the heart of the system;
- **[Xray-core](https://github.com/XTLS/Xray-core)** (XTLS) — transport: VLESS, REALITY, XHTTP, balancing;
- **[nginx](https://nginx.org/)** — the server's facade and TLS termination;
- **[Let's Encrypt](https://letsencrypt.org/) / [certbot](https://certbot.eff.org/)** — certificates;
- **[AmneziaWG](https://github.com/amnezia-vpn)** — obfuscated WireGuard, 3.1 Header Protection profile;
- **[Hysteria](https://github.com/apernet/hysteria)** (apernet) — Hysteria 2, UDP/QUIC transport;
- **[Bubble Tea](https://github.com/charmbracelet/bubbletea) / [Lipgloss](https://github.com/charmbracelet/lipgloss)** (charmbracelet) — the TUI;
- **[freeze-check](https://github.com/MarkSinD/freeze-check)** (MarkSinD, MIT) — the idea behind TCP "freeze" measurement;
- **[v2ray-rules-dat](https://github.com/Loyalsoldier/v2ray-rules-dat)** (Loyalsoldier) — routing geodata;
- **[Mihomo](https://github.com/MetaCubeX/mihomo)** and **[sing-box](https://github.com/SagerNet/sing-box)** — subscription formats for their clients.

XKIT is MIT-licensed. Third-party components retain their own licenses.

<div align="center">

**[⬆ Back to top](#-xkit)**

</div>
