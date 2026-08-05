# ProxyCTL

Unified proxy manager for Xray and sing-box.

## Overview

ProxyCTL provides a single, consistent interface for managing both Xray and
sing-box proxy cores. It handles installation, configuration generation,
service management, TLS certificates, and system optimisation.

## Phase 1 — Architecture Skeleton

This phase establishes the project skeleton, module boundaries, Engine API,
capability system, and terminal menu framework.

### Directory Layout

```text
proxyctl/
├── proxyctl.sh          # Entry point / CLI dispatcher
├── install.sh           # System installer
├── README.md
├── CHANGELOG.md
├── lib/
│   ├── core.sh          # Engine dispatcher (engine_call)
│   ├── ui.sh            # Terminal UI primitives
│   ├── capability.sh    # V1 protocol & transport definitions
│   ├── metadata.sh      # /var/lib/proxyctl/meta.json management
│   ├── transaction.sh   # Atomic config transactions
│   ├── menu.sh          # Interactive menus
│   ├── common/
│   │   ├── system.sh
│   │   ├── network.sh
│   │   ├── port.sh
│   │   ├── lock.sh
│   │   ├── certificate.sh
│   │   ├── backup.sh
│   │   └── bbr.sh
│   ├── xray/
│   │   └── engine.sh
│   └── singbox/
│       └── engine.sh
└── tests/
    └── smoke.sh
```

### CLI Commands

```bash
proxyctl              # Interactive menu
proxyctl help         # Usage information
proxyctl version      # Show version
proxyctl status       # Show engine status
```

### Engine API

Each engine (`xray`, `singbox`) implements a uniform API:

| Method              | Description                    |
|---------------------|--------------------------------|
| `installed`         | Check if engine is installed   |
| `version`           | Get engine version             |
| `install`           | Install engine (stub)          |
| `update`            | Update engine (stub)           |
| `uninstall`         | Uninstall engine (stub)        |
| `start`             | Start engine service (stub)    |
| `stop`              | Stop engine service (stub)     |
| `restart`           | Restart engine service (stub)  |
| `enable`            | Enable auto-start (stub)       |
| `disable`           | Disable auto-start (stub)      |
| `is_active`         | Check if service is running    |
| `validate`          | Validate config file (stub)    |
| `logs`              | View engine logs (stub)        |
| `config_file`       | Return path to config file     |
| `service_name`      | Return systemd service name    |

Dispatch via `engine_call <engine> <method> [args...]`.

### V1 Capabilities

**Xray** — VLESS, VMess, Trojan, SOCKS5, HTTP  
**sing-box** — AnyTLS, VLESS, Hysteria2, Trojan, SOCKS5, HTTP

### Paths

| Path                         | Purpose               |
|------------------------------|-----------------------|
| `/usr/local/sbin/proxyctl`   | Binary                |
| `/usr/local/lib/proxyctl/`   | Library               |
| `/var/lib/proxyctl/`         | Runtime data          |
| `/var/lib/proxyctl/meta.json`| Metadata              |
| `/etc/proxyctl/certs/`       | TLS certificates      |
| `/var/backups/proxyctl/`     | Backups               |
| `/run/lock/proxyctl.lock`    | Lock file             |
| `/usr/local/etc/xray/config.json` | Xray config      |
| `/etc/sing-box/config.json`  | sing-box config       |

## Requirements

- Bash 4.0+
- `jq` (for metadata operations)
- `flock` (for advisory locking)

## Development

Set `PROXYCTL_DEV_LIB` to use a local library directory:

```bash
PROXYCTL_DEV_LIB=./lib ./proxyctl.sh
```

## License

MIT
