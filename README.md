# ProxyCTL 0.2.7

Unified proxy manager for Xray and sing-box.

> **Phase 2 — Common Infrastructure: complete**

## Requirements

- Linux
- Bash 4.0+
- jq
- flock (util-linux)
- iproute2 (`ip`, `ss`)
- curl
- OpenSSL
- tar

DNS resolution prefers `getent` (glibc/musl) and falls back to `nslookup`;
`dig` is never required. Certbot is managed lazily in an isolated Python virtual
environment when ACME functionality is first used.

## Implemented

- **Project skeleton** with strict module boundaries
- **Engine Registry** — unified `engine_call xray|singbox <method>` dispatcher
- **Engine API** — both engines expose all 14 standard methods
- **Capability system** — fixed V1 protocol/transport scope
- **Metadata** — JSON-backed persistent state at `/var/lib/proxyctl/meta.json`
- **System abstraction** — distro, architecture, init system, package manager,
  hostname and package operations
- **Service abstraction** — unified systemd/OpenRC service API
- **Network utilities** — IP/domain validation, route/interface detection,
  public-IP lookup, DNS resolution and TCP connectivity checks
- **Port utilities** — TCP/UDP listener inspection, process lookup, fail-closed
  free-port checks and randomized allocation
- **Process locking** — non-blocking `config` / `cert` / `firewall` `flock`
  locks under the private `/run/proxyctl/` runtime directory
- **Config apply transactions** — real Xray/sing-box core validation, validated
  snapshots, same-directory atomic rename, service health checks and rollback
- **Shared certificate manager** — ported from xrayctl and generalized for both
  engines: isolated Certbot, Cloudflare DNS, HTTP standalone/nginx, manual DNS,
  IP certificates, self-signed/import, renewal metadata and safe deletion
- **Atomic certificate pair sync** — certificate/key staging, OpenSSL pair
  validation, previous-pair recovery and engine-neutral consumer restart
- **Shared certificate access** — `/etc/proxyctl/certs/<identifier>/` plus the
  `proxyctl-cert` supplementary group for Xray and sing-box
- **Portable backup/restore** — archives both engine configs, ProxyCTL metadata,
  managed certificate pairs and optional Cloudflare credentials under config +
  certificate locks. Restore reuses `apply_candidate` and `_cert_replace_pair`
  instead of maintaining a second config/certificate transaction mechanism
- **CLI** — status, certificate management and portable backup management
- **Safe installer** — transactional library/binary/symlink install and rollback
- **Phase 2 integration suite** — exercises metadata + locks + config transactions
  + certificate replacement + portable backup/restore in one temporary runtime
- **GitHub Actions CI definition** — runs syntax, smoke, module, backup and
  integration suites on Ubuntu for pushes and pull requests

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

ACME behavior follows the mature xrayctl policy:

- Cloudflare DNS validation does not need port 80.
- HTTP validation uses standalone mode when port 80 is free.
- If Xray or sing-box owns port 80, ProxyCTL temporarily stops/restores that
  managed engine for issuance.
- If nginx owns port 80, Certbot's nginx authenticator is used.
- Apache/unknown port-80 owners are never killed automatically.
- IP certificates use Certbot's short-lived IP-certificate profile and require
  HTTP validation.
- Manual DNS certificates are recorded as non-auto-renewable.

## Backup CLI

```text
proxyctl backup create [label]
proxyctl backup list
proxyctl backup restore <backup-id>
```

Portable archives are stored as mode-600 `tar.gz` files under
`/var/backups/proxyctl/`. They include:

```text
manifest.json
metadata/meta.json
engines/xray/config.json        # when present
engines/singbox/config.json     # when present
certs/<identifier>/fullchain.pem
certs/<identifier>/privkey.pem
secrets/cloudflare.ini          # when configured
```

This is intended to preserve the node identity across VPS migration: UUIDs,
passwords, Reality parameters, transport settings and managed TLS files remain
unchanged, so clients using the same domain/port generally do not need to be
re-imported.

Certbot's Python environment, logs and internal lineage/work tree are deliberately
not portable. Restored managed certificate files remain usable immediately, but
Let's Encrypt certificates should be reissued on the destination before their
next renewal so Certbot owns a fresh local lineage.

Restore validates archive paths/types before extraction, validates metadata,
certificate/key pairs and installed-engine configs, snapshots the current state,
and then reuses the existing config/certificate transaction APIs. If restore
fails, ProxyCTL attempts to restore the pre-restore snapshot; a failed rollback
is reported as `[CRITICAL]` and its recovery directories are retained.

## V1 Capabilities

| Engine | Protocols |
|---|---|
| Xray | VLESS, VMess, Trojan, SOCKS5, HTTP |
| sing-box | AnyTLS, VLESS, Hysteria2, Trojan, SOCKS5, HTTP |

### Transport scope

```text
Xray
  VLESS   → RAW / XHTTP / WebSocket
  VMess   → RAW / WebSocket
  Trojan  → RAW / WebSocket
  SOCKS5  → none
  HTTP    → none

sing-box
  AnyTLS     → none
  VLESS      → RAW / WebSocket
  Hysteria2  → dedicated HY2 flow
  Trojan     → RAW / WebSocket
  SOCKS5     → none
  HTTP       → none
```

## System Paths

| Path | Purpose |
|---|---|
| `/usr/local/sbin/proxyctl` | Binary |
| `/usr/local/bin/proxyctl` | Symlink |
| `/usr/local/lib/proxyctl/` | Library |
| `/var/lib/proxyctl/meta.json` | Manager metadata |
| `/etc/proxyctl/certs/<id>/fullchain.pem` | Managed certificate copy |
| `/etc/proxyctl/certs/<id>/privkey.pem` | Managed private-key copy |
| `/etc/proxyctl/cloudflare.ini` | Cloudflare DNS credentials |
| `/opt/proxyctl/certbot/` | Isolated Certbot virtual environment |
| `/var/lib/proxyctl/letsencrypt/config/` | Local Certbot lineage/config state |
| `/var/lib/proxyctl/letsencrypt/work/` | Certbot work state |
| `/var/log/proxyctl/certbot/` | Certbot logs |
| `/var/backups/proxyctl/` | Portable backup archives |
| `/run/proxyctl/config.lock` | Config lock |
| `/run/proxyctl/cert.lock` | Certificate lock |
| `/run/proxyctl/firewall.lock` | Firewall lock |

## Security invariants

- Actual Xray/sing-box configs remain the configuration source of truth;
  metadata is auxiliary manager state.
- Metadata writes are validated and atomically renamed.
- Transaction labels/IDs/stage names and backup IDs/archive members are
  validated against strict formats; traversal and link archive entries fail.
- `apply_candidate` applies the exact snapshot that passed real core validation.
- Failed config rollback preserves `old-config` and transaction state.
- Lock files use held-open kernel `flock`, not file-existence semantics.
- Managed certificate identifiers cannot escape their certificate root.
- Certificate/private-key public keys must match before replacement.
- Cloudflare credentials and backup archives are mode 600.
- Unknown port-80 processes are never stopped automatically.
- Backup/restore takes locks in the fixed order `config → cert`.

## Tests

```bash
bash tests/smoke.sh
bash tests/system.sh
bash tests/service.sh
bash tests/network.sh
bash tests/port.sh
bash tests/lock.sh
bash tests/lock_security.sh
bash tests/transaction.sh
bash tests/certificate.sh
bash tests/backup.sh
bash tests/integration.sh
```

The repository also contains `.github/workflows/ci.yml` to execute the same
Phase 2 test stack in GitHub Actions. A workflow definition existing in the
repository is not itself evidence that a particular commit passed CI; check the
actual Actions result for the commit being deployed.

## Next phase

Phase 3 can now focus on real core installation and protocol/inbound builders;
common locking, transactions, certificates, backup/restore and integration
infrastructure are already separated from engine-specific JSON generation.

## License

MIT
