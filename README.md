# ProxyCTL 0.1.1

Unified proxy manager for Xray and sing-box.

> **Phase 1 — Architecture Skeleton (Hardened)**

## Requirements

- Linux
- Bash 4.0+
- jq
- flock

## Implemented

- **Project skeleton** with strict module boundaries
- **Engine Registry** — unified `engine_call xray|singbox <method>` dispatcher
- **Engine API** — both engines expose all 14 standard methods (mostly stubs)
- **Capability system** — V1 protocol and transport definitions (no hard-coded menus)
- **Menu skeleton** — interactive terminal UI with inbound creation wizard
- **Metadata** — JSON-backed persistent state at `/var/lib/proxyctl/meta.json`
- **Transaction staging framework** — staging with commit/rollback and path-safety guards
- **UI library** — `heading`, `info`, `warn`, `error`, `die`, `pause`, `confirm`,
  `choose`, `prompt_value`, `prompt_optional`, `prompt_secret`,
  `prompt_hidden_secret`, `table_header`, `table_row`, `table_footer`
- **CLI** — `proxyctl help`, `proxyctl version`, `proxyctl status`, `proxyctl menu`
- **Safe installer** — staged lib/binary installation with automatic rollback on failure
- **Smoke test suite** — comprehensive security and functional assertions

## Planned (future phases)

- Core installation (Xray, sing-box)
- Real configuration generation (VLESS, VMess, Trojan, AnyTLS, Hysteria2, …)
- TLS certificate management (self-signed + ACME)
- Service operations (start/stop/restart/enable/disable via systemd)
- Backup and restore
- Firewall setup
- BBR congestion control
- Migration from xrayctl / sbctl

## V1 Capabilities

| Engine    | Protocols                          |
|-----------|------------------------------------|
| Xray      | VLESS, VMess, Trojan, SOCKS5, HTTP |
| sing-box  | AnyTLS, VLESS, Hysteria2, Trojan, SOCKS5, HTTP |

## Directory Layout

```text
proxyctl/
├── proxyctl.sh              # CLI entry point / dispatcher
├── install.sh               # System installer (ProxyCTL only)
├── lib/
│   ├── core.sh              # Engine dispatcher
│   ├── ui.sh                # Terminal UI primitives
│   ├── capability.sh        # Protocol & transport definitions
│   ├── metadata.sh          # Persistent state management
│   ├── transaction.sh       # Config transaction staging
│   ├── menu.sh              # Interactive menus
│   ├── common/              # Shared utilities
│   │   ├── system.sh
│   │   ├── network.sh
│   │   ├── port.sh
│   │   ├── lock.sh
│   │   ├── certificate.sh
│   │   ├── backup.sh
│   │   └── bbr.sh
│   ├── xray/engine.sh       # Xray engine
│   └── singbox/engine.sh    # sing-box engine
└── tests/smoke.sh           # Test suite
```

## System Paths

| Path                              | Purpose        |
|-----------------------------------|----------------|
| `/usr/local/sbin/proxyctl`        | Binary         |
| `/usr/local/bin/proxyctl`         | Symlink        |
| `/usr/local/lib/proxyctl/`        | Library        |
| `/var/lib/proxyctl/meta.json`     | Metadata       |
| `/etc/proxyctl/certs/`            | Certificates   |
| `/var/backups/proxyctl/`          | Backups        |
| `/run/lock/proxyctl.lock`         | Lock file      |

## Security

- Metadata keys are validated against an allowlist — no dynamic jq key injection
- Transaction labels, IDs, and stage names are strictly validated
- Transaction path safety uses canonical path resolution (realpath or cd+pwd -P)
- Metadata writes use atomic temp-file-in-same-directory + mv
- Corrupt or invalid JSON writes are detected and rejected before overwriting metadata
- All unimplemented mutating operations fail closed (non-zero exit)
- Installer uses staged updates with automatic rollback on failure
- Data directories are created with mode 700

## Development

```bash
# Source-checkout mode
PROXYCTL_DEV_LIB=./lib ./proxyctl.sh version

# Simulate installed layout
PROXYCTL_LIB=./lib ./proxyctl.sh version

# Run tests
bash tests/smoke.sh
```

## License

MIT
