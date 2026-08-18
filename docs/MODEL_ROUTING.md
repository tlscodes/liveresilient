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
- `.claude/settings.json` defaults this repo to **Fable** for new sessions, and
  says so in its own `_why_model` note (user decision 2026-07-27). Use
  `/model opus` when you open `adaptive_transport` or `connection_orchestrator`.
  (An earlier draft of this line said the file pinned the repo to Opus; that
  contradicted both the paragraph above it and the file itself. Corrected
  2026-07-31 against `.claude/settings.json`, which is the ground truth here
  because it is the thing the tool actually reads.)
- A running session ignores `.claude/settings.json`; `/model` is what changes
  the model mid-session.
- `session-clarity-watch.py` scores the live conversation, and the
  UserPromptSubmit guard hook warns before a turn is stopped rather than after.

## Update 2026-08-12 — a stop is now a HARD STOP, and what that changes

Everything above stays true. One premise underneath it does not.

The `_why_model` note in `.claude/settings.json` accepted stops on transport
turns because "the platform switches that single turn to Opus and the work
continues". That fallback no longer exists: `~/.claude/settings.json` sets

```
CLAUDE_CODE_DISABLE_REFUSAL_FALLBACK = 1
```

so a flagged turn now returns no answer at all instead of quietly changing
model. The repo default is unchanged and the user decision stands — but the
cost of hitting the threshold went from "a slightly different model answered"
to "nothing answered".

**Measured this date.** A fresh session was opened on Fable to review

```
docs/PLAN_five_tickets_v1.md      584 lines
```

It read the prompt file, read the plan, and the request was blocked outright.
Scanner output on that file beforehand, for the record:

```
clusters co-occurring: 2   weighted-score: 13   total-hits: 6
VERDICT: LIKELY-FLAG
hits: relay_proxy_infrastructure x5 · covert_surveillance x1
```

Five of the six hits are real identifiers — a file name, a `SecureSocket.secure`
call site with its line number, and the title of an open ICE-nomination defect
that three sections depend on. Per the standing rule, none of them were
reworded: renaming real identifiers would mislead the next maintainer and would
not move an aggregate score anyway.

**The rule this adds.** The existing rules scope by PACKAGE. That is not enough
for design documents, because a document is not scoped by package at all — this
one cites `adaptive_transport`, `connection_orchestrator` and `signed_config`
in the same file by necessity, since its whole subject is how those three
interact. So:

- A cross-package design document, plan, or review brief is an **Opus** job,
  regardless of which packages it names. Open the session with `/model opus`
  before the first read.
- Splitting such a document into per-ticket single-topic sessions is the
  fallback when Opus is unavailable. It costs the thing the document exists
  for — the dependencies between tickets — so it is a fallback, not a plan.
- Before handing any document to a review session, run
  `content-clarity-scan.py --session <file>` and record the verdict in the
  review prompt. A LIKELY-FLAG verdict is not a reason to edit the document;
  it is a reason to choose the model.
