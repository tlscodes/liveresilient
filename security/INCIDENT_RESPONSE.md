# Incident Response Runbook — VoiceCallKit v2

Applies to: production signaling service, config service, TURN fleet, push
integration, app-level security defects, and key-compromise events.

## 1. Severity levels

| Level | Definition | Examples | Response clock |
|---|---|---|---|
| SEV-1 | Active compromise or content exposure | Manifest signing key compromise; media confidentiality break; malicious release | Page on-call immediately; work continuously |
| SEV-2 | Security control failure without confirmed exposure | Verifier check-skip bug; TOFU pinning defect; redaction failure shipping PII to logs | Respond < 4h |
| SEV-3 | Major availability incident | Signaling fleet down; TURN exhaustion; config service outage past manifest grace period | Respond < 8h |
| SEV-4 | Degraded service / contained defect | Elevated call-setup failures; a region's TURN latency spike | Next business day |

## 2. Roles

- **Incident Commander (IC):** owns the timeline, decisions, and comms.
- **Ops lead:** infra actions (coturn, monitoring, deploys, rollbacks).
- **Security lead:** forensics, key handling, disclosure assessment.
- **Comms owner:** status page and user notification drafts.

One person may hold multiple roles in a small rotation, but every incident
names an IC in the first 15 minutes.

## 3. Standard flow

1. **Detect / declare.** Any responder may declare; monitoring alerts from
   `infra/monitoring` auto-open a SEV-3 draft.
2. **Stabilize (smallest reversible step first).** Prefer: rotate a
   credential, disable a feature flag, roll back one release. Avoid
   architecture changes during the fire.
3. **Preserve evidence.** Snapshot logs (already redacted at write time —
   see `packages/security/lib/src/log_redactor.dart`), config revisions,
   and deploy identifiers before further mutation.
4. **Eradicate / recover.** Fix root cause, redeploy, verify with the
   monitoring checks that detected the issue.
5. **Notify.** See §5.
6. **Post-incident review** within 5 working days: blameless, written,
   with action items tracked to closure. Update `THREAT_MODEL.md` if the
   incident revealed a new threat or invalidated a mitigation.

## 4. Playbooks

### 4.1 Manifest signing key compromise (SEV-1)
1. Mark the compromised key `revoked` in the pinned key set; ship an
   emergency app release signed with the standby key.
2. Rotate config-service TLS credentials.
3. Publish a new manifest with a **higher revision** so rollback
   protection prevents replays of attacker manifests on updated clients.
4. Announce the affected version range; older clients within the
   last-known-good grace window remain on their cached (authentic)
   manifests, which limits blast radius.

### 4.2 Signaling service compromise (SEV-1/2)
1. Isolate affected hosts; rotate service credentials and TURN shared
   secrets.
2. Audit what metadata was exposed (message bodies are opaque; media never
   transits signaling).
3. Force reconnect of all clients (they re-authenticate; outboxes make the
   reconnection lossless).

### 4.3 Defective release (SEV-2)
1. Halt rollout at the app stores' staged-rollout controls.
2. Roll back the server side if the defect is server-coupled.
3. Verify the previous version against the current manifest schema before
   directing users to it.

### 4.4 TURN/media availability (SEV-3)
1. Check coturn capacity and credential-minting rates.
2. Add capacity or shed video (clients already downshift via
   `AdaptiveMediaPolicy`; audio-only survives ~16 kbps).

### 4.5 Region outage — TURN or signaling region down (SEV-2)
Added 2026-07-16 (Phase 10 gate: runbooks complete). Client-side failover is
already automatic; this runbook is the operator half.
1. Confirm scope: one region vs many — check region health signals and the
   provider status page. Clients using `RelayPool` (adaptive_transport) mark the
   dead region's circuit open after consecutive failures and move NEW calls to
   the next healthy region automatically; no client action needed.
2. Signaling: if a signaling node/region is down, clients reconnect via
   `ReconnectPolicy` backoff and `ReliableOutbox` resends undelivered frames on
   resume. Until multi-node clustering ships (dated blocker, Phase 6 STATUS),
   a full signaling outage is a hard outage — restore the node first.
3. Mitigate: shift traffic by editing the signed endpoint manifest — remove the
   dead region from `relayRegions` / reorder `signalingEndpoints`, bump
   `revision`, re-sign (`packages/signed_config/bin/sign_manifest.dart`), publish
   to ALL healthy config origins. Clients pick it up on next refresh; the
   last-known-good cache keeps existing clients working meanwhile.
4. Do NOT rotate keys during a region outage unless compromise is suspected
   (see 4.1) — rotation and outage recovery must not be mixed.
5. Recover: when the region returns, restore the manifest (new revision),
   watch `RelayPool` re-admit it (half-open probes earn re-selection; hysteresis
   prevents flap-back), and verify relay egress returns to baseline in the cost
   dashboard (`docs/OPERATIONS.md` cap still applies).
6. Post-incident: record relayed-minute delta and any budget-alert firings in
   the incident log; update `docs/OPERATIONS.md` if the cap proved wrong.

## 5. User notification

- Content exposure or key compromise: notify affected users in-app in
  plain language within 72 hours of confirmation, including what happened,
  what it means for them, and what we changed.
- Availability incidents: status page only.
- Never downplay: the product's users may face real risk; honesty is a
  safety feature.

## 6. Contact tree and drills

- Current on-call schedule lives in `infra/monitoring` alert routing.
- A tabletop drill of playbook 4.1 runs every 6 months; its findings feed
  back into this document.
