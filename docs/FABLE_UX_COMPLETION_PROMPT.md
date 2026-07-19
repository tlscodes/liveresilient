# Fable 5 — finish the chat/UX layer (updated, gated)

Supersedes the audit prompt for this phase. Paste the block below into Fable 5 at
`/Users/behnam/Downloads/voice_call_kit_v3`. Plain UI/app work — stays in the clean core,
never names the plugins workspace, so it will not flag. If the session was long, run
`/compact` first.

Current state (verified):
- 913 tests green across 16 directories; `dart analyze --fatal-infos --fatal-warnings` clean.
- Chat + chunked attachments already ride the call's WebRTC data channel via the
  `messaging_webrtc_adapter` package (E2E proven over a TLS relay).
- In progress, UNCOMMITTED: a periodic retry driver was started in
  `apps/reference_app/lib/main.dart` (Task 1) — finish, test, and commit it first.

```text
Resume the reference_app chat/UX work. 913 tests are green; keep them green. After EACH task
run:  dart format .  ·  dart analyze --fatal-infos --fatal-warnings  ·  the named test file(s)
A task is done only when all are clean. Commit after each green task with a clear message.
Do not weaken or delete tests. Work only in apps/reference_app and packages/messaging.

TASK 1 — Periodic retry driver (finish the in-progress edit).
In apps/reference_app/lib/main.dart chat controller, run a periodic Timer (500 ms) during an
active call that calls _local.tick() and _peer?.tick(); cancel it in dispose(). Add a widget/
unit test that a pending message is retransmitted after the retry window elapses. Verify with
`flutter test test/chat_call_channel_test.dart`, then commit.

TASK 2 — Delivery status in the chat bubbles.
Subscribe to the messenger's delivery stream and show a per-message marker (pending →
delivered → failed) on each outbound bubble. Add a widget test asserting the marker updates
on a delivery event. Verify and commit.

TASK 3 — Attachment transfer progress.
In the attachment send path, expose a progress stream (bytesSent / totalBytes) — add it to
sendAttachment / a small transfer handle in packages/messaging without breaking existing
callers. Render a standard progress bar in the attachment bubble. Unit-test the progress
stream emits 0→100%. Verify and commit.

TASK 4 — Attachment picker button.
Add a file/media picker button to the chat screen that, on selection, starts the chunked
attachment transfer over the live data channel and shows the Task-3 progress bar. Use a
standard picker; keep the widget testable (inject the picker so a test can drive it without a
real file dialog). Verify and commit.

FINAL — Run the full gate across the workspace (dart analyze + every package's tests) and
update docs/STATUS.md: test count, the four features added, and any item still needing a
physical device (real SCTP data channel) listed as a dated blocker. Do not claim device-only
items as done.
```

Note: the only inherently device-bound piece is the platform SCTP pipe (needs a real phone);
everything above is testable in-process today.
```
