# OPERATIONS — cost model, budget caps, and operational guards

Created 2026-07-16 as the Phase 6 mandatory pre-gate artifact
(`UPGRADE_BLUEPRINT_V3.md` §فاز ۶, lines 817-842: "بدون سقف بودجه ثبت‌شده و alert فعال، این فاز شروع نمی‌شود").

## 1. TURN relay egress — the dominant recurring cost

TURN relays media when a direct/ICE path fails; every relayed minute is billable
egress on the provider hosting coturn. Cost scales with the **relayed** share of
call minutes, not total minutes.

### Formula (source: UPGRADE_BLUEPRINT_V3.md:824-833)

```
monthly_egress_GB ≈ relayed_minutes_per_month × MB_per_relayed_minute / 1024

MB_per_relayed_minute:
  audio (Opus, mono, typical)   ≈ 0.75 MB/min
  video (adaptive, low→high)    ≈ 7–15 MB/min

monthly_cost ≈ monthly_egress_GB × provider_egress_rate_per_GB
```

`provider_egress_rate_per_GB` = **TBD at deployment** — read it off the chosen
provider's current price sheet on the day the first Phase-6 coturn deploys and
record it here. Do NOT reuse a remembered number.

### Scenario grid (egress volume only; multiply by the real €/GB when known)

| relayed min/month | audio 0.75 MB/min | video 7 MB/min | video 15 MB/min |
|---:|---:|---:|---:|
| 1,000   | 0.73 GB  | 6.8 GB   | 14.6 GB  |
| 10,000  | 7.3 GB   | 68.4 GB  | 146.5 GB |
| 100,000 | 73.2 GB  | 683.6 GB | 1,464.8 GB |

Grid math: `relayed_minutes × MB_per_min / 1024`, e.g. `10,000 × 0.75 / 1024 = 7.32 GB`.

### The ratio that must be MEASURED, not guessed

`relayed_minutes = total_call_minutes × relayed_ratio`. The blueprint requires
the relayed/direct ratio to come from Phase 5 telemetry on real traffic
(UPGRADE_BLUEPRINT_V3.md:834-836). Industry folklore says 10-20% of calls need
TURN, but **no number goes into capacity planning until our own telemetry
reports it**. Telemetry source: `privacy_telemetry` package counters
(consent-gated), field name to be fixed when the reference app lands.

## 2. Budget cap and alert — HARD deployment gate

| Guard | Status 2026-07-16 |
|---|---|
| Monthly TURN egress cap recorded here | **SET: 50 GB/month soft cap for the first deployment window** (revisit with real telemetry; at audio-only traffic this is ~68k relayed minutes — see grid) |
| Provider budget alert active before first coturn deploy | **BLOCKED (dated 2026-07-16):** no cloud provider account/deployment exists yet — the alert can only be created in the provider console at deploy time. Scheduled slot: the same work session that deploys the first Phase-6 coturn node. Deploying coturn WITHOUT this alert violates the blueprint gate (UPGRADE_BLUEPRINT_V3.md:842) and is forbidden. |
| Region choice co-located with users | Decide from signaling-server connection origins at deploy time (UPGRADE_BLUEPRINT_V3.md:839-841). |

## 3. Operational checklist before ANY Phase-6 infra deploy

1. Re-read this file; fill in `provider_egress_rate_per_GB` from the live price sheet.
2. Create the provider budget alert at the cap in §2 — screenshot/ID recorded here.
3. Confirm coturn uses `use-auth-secret` short-lived credentials
   (`packages/security` `TurnCredentialsIssuer`, already implemented+tested) — the
   static `lt-cred-mech` pair in `infra/turn/turnserver.conf` is LOCAL DEV ONLY.
4. Enable TLS listener (`listening-tls-port`) — dev config runs UDP/TCP only.
5. Verify telemetry counters for relayed-vs-direct ratio are flowing before
   scaling to a second region.
