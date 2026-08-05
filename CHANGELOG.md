# Changelog

## [1.0.0] — Unreleased

### Added

- Project skeleton and directory layout
- Engine API dispatcher (`engine_call`) with full method interface
- Xray engine stub with complete API surface
- sing-box engine stub with complete API surface
- V1 protocol and transport capability definitions
- Interactive terminal menu system (main, inbound, core, system)
- Inbound creation wizard (engine → protocol → transport → print)
- Terminal UI primitives (heading, info, warn, error, die, pause, confirm, choose, prompts, table)
- Metadata management with JSON init/validate/get/set
- Transaction framework (begin/stage/commit/rollback)
- Common modules: system, network, port, lock, certificate, backup, BBR
- CLI: `proxyctl`, `proxyctl help`, `proxyctl version`, `proxyctl status`
- System installer (`install.sh`)
- Smoke test suite
