# ProxyCTL 0.2.5

Unified proxy manager for Xray and sing-box.

> **Phase 2 — Common Infrastructure**

## Requirements

- Linux
- Bash 4.0+
- jq
- flock (util-linux)
- iproute2 (`ip`, `ss`)
- curl
- OpenSSL

DNS resolution prefers `getent` (glibc/musl) and falls back to `nslookup`;
`dig` is never required. Certbot is managed lazily in an isolated Python virtual
environment when ACME functionality is first used.

## Implemented

- **Project skeleton** with strict module boundaries
- **Engine Registry** — unified `engine_call xray|singbox <method>` dispatcher
- **Engine API** — both engines expose all 14 standard methods
- **Capability system** — V1 protocol and transport definitions (no hard-coded menus)
- **Menu skeleton** — interactive terminal UI with inbound creation wizard
- **Metadata** — JSON-backed persistent state at `/var/lib/proxyctl/meta.json`
- **Transaction staging framework** — staging with commit/rollback and path-safety guards
- **System abstraction** — OS, distro, architecture, init system, package manager,
  hostname detection with canonical arch tokens (`amd64`, `arm64`, `armv7`, `386`)
- **Service abstraction** — unified `service_*` API over systemd and OpenRC
  (`start`/`stop`/`restart`/`enable`/`disable`/`is_active`/`is_enabled`/`logs`)
- **Network utilities** — IPv4/IPv6/domain/host validation, default-interface and
  primary-IP detection from `ip route get`, public-IP detection with a timed
  3-provider fallback, DNS resolution (getent → nslookup), timed TCP connect
- **Port utilities** — TCP/UDP listening inspection via `ss` (netstat fallback),
  exact port matching, process lookup, free-port checks that fail closed on
  inspection errors, and randomized free-port allocation
- **Process locking** — `flock`-backed `config`/`cert`/`firewall` locks on fixed
  fds with non-blocking `lock_acquire`, idempotent `lock_release`,
  `lock_is_held`, and `with_lock`. Runtime lock files live under the dedicated
  `/run/proxyctl/` directory rather than directly in the shared `/run/lock`;
  symlink, special-file, foreign-owner, and insecure-parent lock paths are
  rejected before opening. Locks are released automatically by the kernel on
  process exit and lock files are never deleted.
- **Config apply transactions** — `apply_candidate <engine> <candidate>` applies
  a new Xray / sing-box config safely under the config lock: real core
  validation (`xray run -test -config` / `sing-box check -c`), same-directory
  temp + atomic rename, old-permission preservation, and automatic rollback
  (config restored, service restarted, or removed when there was no previous
  config) on any failure. Inactive services are validated and replaced but not
  started. Failed rollbacks preserve the transaction and recovery copy.
- **Shared certificate manager** — ported from the mature xrayctl certificate
  lifecycle and generalized for both engines. Features include isolated Certbot
  state, domain and IP certificates, Cloudflare DNS validation, standalone HTTP
  validation, nginx integration, manual DNS, self-signed certificates, imports,
  metadata-managed `identifier` vs Certbot `certName`, renewal status tracking,
  safe deletion, and a systemd renewal timer.
- **Atomic certificate pair sync** — managed pairs are staged, validated with
  OpenSSL, backed up, and replaced as a unit. A failed replacement restores the
  previous pair. Certificate changes restart only active engines whose config
  actually references that managed certificate path.
- **Shared certificate access** — managed certificate copies live under
  `/etc/proxyctl/certs/<identifier>/` and use the `proxyctl-cert` supplementary
  group so Xray and sing-box can consume the same non-world-readable private key.
- **UI library** — `heading`, `info`, `warn`, `error`, `die`, `critical`,
  `pause`, `confirm`, `choose`, `prompt_value`, `prompt_optional`,
  `prompt_secret`, `prompt_hidden_secret`, `table_header`, `table_row`,
  `table_footer`
- **CLI** — `proxyctl help`, `proxyctl version`, `proxyctl status`,
  `proxyctl menu`, and `proxyctl cert ...`
- **Safe installer** — single-transaction install: staged lib/binary swap, atomic
  symlink, metadata init, and a unified rollback that restores the previous
  installation on any failure. Old artifacts are kept until the final commit.
- **Test suites** — `smoke.sh` plus per-module suites (`system.sh`, `service.sh`,
  `network.sh`, `port.sh`, `lock.sh`, `lock_security.sh`, `transaction.sh`,
  `certificate.sh`)

## Certificate CLI

```text
proxyctl cert list
proxyctl cert info <identifier>
proxyctl cert paths <identifier>
proxyctl cert issue <domain|ip> <email> [http|dns-cloudflare|dns-manual] [force]
proxyctl cert self <domain|ip>
proxyctl cert import <identifier> <fullchain.pem> <privkey.pem>
proxyctl cert renew <identifier>
proxyctl cert renew-auto
proxyctl cert delete <identifier>
proxyctl cert cloudflare
```

ACME behavior intentionally follows xrayctl's mature policy:

- Cloudflare DNS validation does not need port 80.
- HTTP validation uses standalone mode when port 80 is free.
- If Xray or sing-box owns port 80, ProxyCTL temporarily stops/restores that
  managed engine for issuance.
- If nginx owns port 80, Certbot's nginx authenticator is used.
- Apache/unknown port-80 owners are never killed automatically.
- IP certificates use Certbot's short-lived IP-certificate profile and require
  HTTP validation.
- Manual DNS certificates are recorded as non-auto-renewable.

## Planned (future phases)

- Core installation (Xray, sing-box)
- Real configuration generation (VLESS, VMess, Trojan, AnyTLS, Hysteria2, …)
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
│   ├── transaction.sh       # Config transaction staging/apply
│   ├── menu.sh              # Interactive menus
│   ├── common/
│   │   ├── system.sh
│   │   ├── network.sh
│   │   ├── port.sh
│   │   ├── lock.sh
│   │   ├── certificate.sh
│   │   ├── backup.sh
│   │   └── bbr.sh
│   ├── xray/engine.sh
│   └── singbox/engine.sh
└── tests/
```

## System Paths

| Path | Purpose |
|---|---|
| `/usr/local/sbin/proxyctl` | Binary |
| `/usr/local/bin/proxyctl` | Symlink |
| `/usr/local/lib/proxyctl/` | Library |
| `/var/lib/proxyctl/meta.json` | Metadata |
| `/etc/proxyctl/certs/<id>/fullchain.pem` | Managed certificate copy |
| `/etc/proxyctl/certs/<id>/privkey.pem` | Managed private-key copy |
| `/etc/proxyctl/cloudflare.ini` | Cloudflare DNS credentials |
| `/opt/proxyctl/certbot/` | Isolated Certbot virtual environment |
| `/var/lib/proxyctl/letsencrypt/config/` | Isolated Certbot lineage/config state |
| `/var/lib/proxyctl/letsencrypt/work/` | Certbot work state |
| `/var/log/proxyctl/certbot/` | Certbot logs |
| `/var/backups/proxyctl/` | Backups |
| `/run/proxyctl/` | Private runtime lock directory |
| `/run/proxyctl/config.lock` | Config lock file |
| `/run/proxyctl/cert.lock` | Certificate lock file |
| `/run/proxyctl/firewall.lock` | Firewall lock file |

## Security

- Metadata keys are validated against an allowlist; certificate metadata fields
  are also explicitly allowlisted.
- Metadata writes use atomic temp-file-in-same-directory + rename and validate
  the resulting JSON before replacement.
- Transaction labels, IDs, and stage names are strictly validated.
- Config apply never overwrites the formal config in place and never applies a
  different file than the exact snapshot validated by the core.
- Failed config rollback preserves its transaction directory and `old-config`
  recovery copy for manual intervention.
- Locking uses kernel `flock` on held-open fixed fds, never lock-file existence.
- Certificate identifiers cannot contain path separators/traversal components.
- Managed certificate directories/files reject symlink targets before replace.
- Certificate/private-key pairs are validated for parseability and matching
  public keys before they are installed.
- Managed pair replacement preserves the previous pair until both new files are
  staged and validated; failed replacement restores the previous state.
- Cloudflare credentials are written atomically with mode 600.
- Unknown port-80 processes are never stopped automatically.
- Certbot uses ProxyCTL-specific config/work/log directories and does not reuse
  `/etc/letsencrypt`.

## Development

```bash
PROXYCTL_DEV_LIB=./lib ./proxyctl.sh version
PROXYCTL_LIB=./lib ./proxyctl.sh version

bash tests/smoke.sh
bash tests/lock.sh
bash tests/lock_security.sh
bash tests/transaction.sh
bash tests/certificate.sh
```

## License

MIT
