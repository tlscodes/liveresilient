# Human-Rights-Informed Design — VoiceCallKit v2

## Framing

Article 19 of the Universal Declaration of Human Rights (UDHR) states that
everyone has the right "to seek, receive and impart information and ideas
through any media and regardless of frontiers." Reliable person-to-person
communication under degraded network conditions serves that right. This
project is *informed by* that framing as a design value.

**Claims discipline:** this project is not endorsed, approved, or
certified by the United Nations or any UN body, and no material in this
repository may state or imply otherwise. Referencing UDHR Article 19
describes our design motivation, not an affiliation. (See also the
repository claims policy: honest capability statements only.)

## What the value means in engineering terms

1. **Resilience without deception.** We maximize delivery within open
   standards — multi-path routing, redundancy, fanout, ICE restarts,
   last-known-good configuration — and we do not add custom traffic-shaping, imitate
   other services, or ship any functionality aimed at defeating network filtering. When the
   network denies service, the app says so honestly instead of pretending.
   This line is enforced mechanically (`tool/architecture_guard.dart`).

2. **Safety of the person over delivery of the packet.** Features that
   could expose users (nearby-device radio visibility, relaying others'
   traffic) default off, behind explicit, revocable, per-feature consent
   with plain-language risk explanations. A user in a dangerous situation
   must never be opted into visibility they did not choose.

3. **Confidentiality as a default, not a tier.** DTLS-SRTP media
   encryption, device-held identity keys, TOFU pinning with human-readable
   safety numbers, and key-change warnings ship in the base product. There
   is no "premium privacy."

4. **Minimal observable metadata.** See `PRIVACY.md`: collect nothing by
   default, aggregate what users opt into, redact what operations needs.
   What the operator cannot see, it cannot be compelled to produce.

5. **Access for everyone.** Accessibility (see `ACCESSIBILITY.md`) is a
   rights issue in a communication tool: Deaf users' need for motion-first
   video shaped the media policy's quality ladder; screen-reader
   announcements of degradation states are acceptance criteria, not polish.

6. **Honesty in failure.** Degraded-mode UX states plainly what works and
   what does not (audio-only fallback, reconnecting, offline). False
   assurance in a crisis is a harm.

## Boundaries we hold

- No surveillance features: no silent call monitoring, no remote
  activation of microphone/camera, no operator backdoor. Requests for such
  capabilities are rejected at the architecture level (no hooks exist to
  attach them to).
- No dual-use drift: the local peer path authenticates every hop and caps
  forwarding precisely so it cannot silently become an anonymized relay
  network users did not consent to participate in.
- No exaggerated safety claims in UI or marketing: the threat model's
  residual risks (`security/THREAT_MODEL.md` §5) are user-facing facts,
  communicated in the app's security explainer.

## Review

Any feature touching consent, identity, telemetry, or the local peer path
requires a design review against this document. The review asks one
question first: *does this change what a user silently reveals to anyone?*
If yes, it needs an explicit consent surface and an update to
`PRIVACY.md` before implementation.
