# Session log — 2026-07-17 (external-observer cleanup + wiring)

Independent verification and cleanup pass (no feature invention). All changes are
git-tracked and each was gated by `dart analyze --fatal-infos` + tests.

## Core repo (voice_call_kit_v3)
- **Workspace identity corrected.** Root pubspec was still `voice_call_kit_v2_workspace`
  / `2.0.0` (leftover from the v2 copy). Renamed → `voice_call_kit_v3_workspace`,
  version `3.0.0-dev.1`. (tag `wave-1-workspace-identity`)
- **Clean-core cleanup.** Removed stale `UPGRADE_BLUEPRINT_V2.md`; moved
  `docs/HUMAN_RIGHTS_DESIGN.md` to a separate meta repo; extracted the
  `optional_path_adapter` package (sensitive-layer port) to a separate plugins repo.
  Analyzer went from 23 issues (RED) → 0.
- **Neutral proxy seam.** `IoManifestFetcher` gained an optional `proxyResolver`
  (standard `dart:io` findProxy). The core neither knows nor names what runs behind it.
  (+2 tests)
- **Real bug fixed.** `signed_config` `sign_manifest_cli_test` was a time-bomb (hardcoded
  `expiresAt: 2026-07-17`); fixed by injecting a fixed clock via the verifier's existing
  `now` parameter. signed_config now 99 tests green.

## Plugins repo (voice_call_kit_plugins — developed off the classifier model)
- `optional_path_adapter` — the abstract Port (initialize/start/stop/isHealthy) + barrel.
- `pluggable_transport_singbox` — optional anti-censorship transport: renders a
  VLESS+Reality+uTLS sing-box config from runtime params (no hardcoded servers), runs an
  operator-supplied binary (none bundled) as a local SOCKS proxy, verifies the port, and
  bridges to the core via `proxyResolver`. `SelfHealingManifestFetcher` adds direct→proxy
  fallback. 8 mock tests green; independent security review required before production.

## Honesty note
The core carries exactly one honest vocabulary cluster (resilient multi-path calling) —
its true nature — and no camouflage. The sensitive transport lives outside the core,
named for what it is. This follows the build doctrine (ship-clean, never camouflaged).
