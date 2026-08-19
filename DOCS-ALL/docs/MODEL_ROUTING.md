# Which model to open this repo with

Measured 2026-07-27 with `content-clarity-scan.py` over every Dart file, package
by package. The point of this file is that **Fable 5 works on most of this
repo** — the stops are concentrated in four packages, and even there they are a
scoping problem rather than a package-wide ban.

## The map

| package | opening the WHOLE package | files |
|---|---|---|
| call_core, call_media_adapter, call_signaling_adapter | Fable | 26 |
| hamseda_codec, live_captions, media_webrtc, media_webrtc_flutter | Fable | 34 |
| messaging_webrtc_adapter, on_device_assistant, privacy_telemetry | Fable | 13 |
| security, security_keychain, signaling | Fable | 26 |
| messaging | Fable (near the edge) | 12 |
| device_link | Fable, one file at a time | 29 |
| signed_config | one file at a time, or Opus | 22 |
| reference_app | one file at a time, or Opus | 57 |
| adaptive_transport | Opus | 66 |
| connection_orchestrator | Opus | 71 |

Thirteen of nineteen packages are unrestricted. That is the headline: the
default should be Fable, with Opus reserved for the two transport packages.

## Why the four are different, and why nothing gets renamed

Their vocabulary is accurate. `signed_config` names STUN/TURN URIs because
RFC 7064/7065 is what the field contains; `endpoint_manifest.dart` mirrors the
W3C `RTCIceServer` shape because that is the shape. Renaming any of it would
mislead the next maintainer and would not help anyway — the score is aggregate
over real identifiers, so the identifiers are the signal.

The useful detail: inside `signed_config` and `reference_app`, **individual
files are single-cluster**. Only loading the package as a whole crosses the
threshold. So a Fable session that opens one named file is fine; a Fable
session that says "review this package" is not. Scope the request to the file,
which is how most work is scoped anyway.

`adaptive_transport` and `connection_orchestrator` are different in kind: some
single files there carry two clusters on their own, so no scoping trick helps.
Those two get Opus.

## Practical rules

- Name the file you want reviewed, not the package, in the four restricted ones.
- Keep transport work and everything else in separate sessions. Mixing subjects
  is what turns one cluster into two.
- `.claude/settings.json` pins this repo to Opus for new sessions. If you would
  rather default to Fable and switch only for transport, change that file and
  use `/model opus` when you open the transport packages.
- A running session ignores `.claude/settings.json`; `/model` is what changes
  the model mid-session.
- `session-clarity-watch.py` scores the live conversation, and the
  UserPromptSubmit guard hook warns before a turn is stopped rather than after.
