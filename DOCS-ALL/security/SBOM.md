# Software Bill of Materials

Scope: the pure-Dart pub workspace anchored at the repo root (`pubspec.yaml`
`workspace:` list). `packages/media_webrtc_flutter` and `apps/reference_app`
resolve independently (Flutter pub, own `pubspec.lock`) and are out of
scope for this document — they belong to a separate workstream.

## Regeneration

From the repo root, after any dependency change:

```
export PATH="/usr/local/bin:$PATH"
dart pub get
awk '/^  [a-zA-Z_0-9]+:$/{pkg=$1; sub(":","",pkg)} /^    source:/{s=$2} /^    version:/{v=$2; gsub("\"","",v); print pkg"|"v"|"s}' pubspec.lock | sort
```

That reproduces the "External dependencies" table below verbatim (pipe-
separated `name|version|source`) from the checked-in `pubspec.lock`, which
is the single source of truth. Workspace-member versions/paths (the first
table) come from each member's own `pubspec.yaml`.

Live vulnerability-database scanning is **not** performed by this
document or by any command above — that needs network access this
environment doesn't have. It is a CI step, not a local one:

```
# CI only (needs network): scans pubspec.lock against the OSV database.
osv-scanner --lockfile=pubspec.lock
```

No CVE claims are made here. Only `dart pub outdated` (also network-free
once packages are already fetched into the pub cache) was run locally —
see the version-currency notes below the dependency table.

## Workspace packages

| Package | Version | Path | Role |
|---|---|---|---|
| voice_call_kit_v2_workspace | 2.0.0 | `.` | Workspace anchor only; no source. |
| adaptive_transport | 2.0.0 | `packages/adaptive_transport` | Transport selection/fallback. |
| call_core | 2.0.0 | `packages/call_core` | Transport-agnostic call state machine. |
| call_signaling_adapter | 2.0.0 | `packages/call_signaling_adapter` | Bridges call_core to signaling. |
| device_link | 2.0.0 | `packages/device_link` | Local-peer envelopes, push wakeup, link forwarding. |
| media_webrtc | 2.0.0 | `packages/media_webrtc` | Pure-Dart WebRTC media plumbing. |
| privacy_telemetry | 2.0.0 | `packages/privacy_telemetry` | Redaction-safe telemetry. |
| security | 2.0.0 | `packages/security` | Ed25519 identity engine, log redaction. |
| signaling | 2.0.0 | `packages/signaling` | Signaling client/envelope types. |
| signed_config | 2.0.0 | `packages/signed_config` | Signed endpoint manifest + verifier. |
| signaling_server | 2.0.0 | `server/signaling_server` | wss:// relay (dumb pipe). |
| fuzz_tool | 2.0.0 | `tool/fuzz` | Dev-only structured-mutation fuzz CLI (this slice). Not shipped. |

`integration_test` is also a workspace member (Dart SDK's own package,
`sdk: flutter`) with no third-party dependencies of its own.

## External dependencies (from `pubspec.lock`, all `hosted` on pub.dev)

Direct runtime dependencies actually imported by shipping workspace
packages: `clock`, `crypto`, `cryptography`. Everything else below is
pulled in transitively by `dev_dependencies` (`test`, `fake_async`) —
none of it ships in a built app.

| Package | Version |
|---|---|
| _fe_analyzer_shared | 99.0.0 |
| analyzer | 12.1.0 |
| args | 2.7.0 |
| async | 2.13.1 |
| boolean_selector | 2.1.2 |
| cli_config | 0.2.0 |
| clock | 1.1.2 |
| collection | 1.19.1 |
| convert | 3.1.2 |
| coverage | 1.15.1 |
| crypto | 3.0.7 |
| cryptography | 2.9.0 |
| fake_async | 1.3.3 |
| ffi | 2.2.0 |
| file | 7.0.1 |
| frontend_server_client | 4.0.0 |
| glob | 2.1.3 |
| http_multi_server | 3.2.2 |
| http_parser | 4.1.2 |
| io | 1.0.5 |
| logging | 1.3.0 |
| matcher | 0.12.19 |
| meta | 1.19.0 |
| mime | 2.0.0 |
| node_preamble | 2.0.2 |
| package_config | 2.2.0 |
| path | 1.9.1 |
| pool | 1.5.2 |
| pub_semver | 2.2.0 |
| shelf | 1.4.2 |
| shelf_packages_handler | 3.0.2 |
| shelf_static | 1.1.3 |
| shelf_web_socket | 3.0.0 |
| source_map_stack_trace | 2.1.2 |
| source_maps | 0.10.13 |
| source_span | 1.10.2 |
| stack_trace | 1.12.1 |
| stream_channel | 2.1.4 |
| string_scanner | 1.4.1 |
| term_glyph | 1.2.2 |
| test | 1.31.0 |
| test_api | 0.7.11 |
| test_core | 0.6.17 |
| typed_data | 1.4.0 |
| vm_service | 15.2.0 |
| watcher | 1.2.1 |
| web | 1.1.1 |
| web_socket | 1.0.1 |
| web_socket_channel | 3.0.3 |
| webkit_inspection_protocol | 1.2.1 |
| yaml | 3.1.3 |

## Version currency (`dart pub outdated`, repo root, 2026-07-17)

All **direct** dependencies are up to date. Seven **dev-only/transitive
dev** packages are locked to versions older than what's now on pub.dev —
none of them reach a shipping build:

| Package | Locked | Latest available |
|---|---|---|
| test | 1.31.0 | 1.31.2 |
| _fe_analyzer_shared | 99.0.0 | 105.0.0 |
| analyzer | 12.1.0 | 14.1.0 |
| matcher | 0.12.19 | 0.12.20 |
| package_config | 2.2.0 | 3.0.0 |
| test_api | 0.7.11 | 0.7.13 |
| test_core | 0.6.17 | 0.6.19 |

No upgrades were performed as part of this slice — this table is a
factual snapshot only, per the task's dep-audit scope.
