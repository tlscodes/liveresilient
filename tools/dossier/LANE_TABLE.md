# Which lane carries what, and which lane the measurements used

Week 0, item 1 of `PLAN_HARDENING.md`. Nobody can reason about what is safe to
ship without this table, and writing it turned up something that changes how the
device measurements may be described.

Everything below was read out of the code today; each row names the file.

## The finding, first

The six end-to-end device rows in `tools/dossier/e2e_ios_results.tsv` were all
measured over `DatagramLanePort` — a test-support class under
`apps/reference_app/integration_test/support/`, carrying raw UDP with no
encryption of its own.

```
src:apps/reference_app/integration_test/e2e_matrix_test.dart

line  47  Future<(DatagramLanePort, DatagramLanePort)> _lanePair(String call)
line 218  chat        _lanePair('t3-chat')
line 263  news        _lanePair('t3-news')
line 305  voice note  _lanePair('t3-voice')
line 355  photo       _lanePair('t3-photo')
line 406  video note  _lanePair('t3-video')
line 459  push-to-talk _lanePair('t3-ptt')
```

The shipping application does not use that lane for chat. It wires the chat
port to the WebRTC data channel:

```
src:apps/reference_app/lib/src/call_session.dart:543
openChatPort: () async => MediaChannelDataPort(await media.openDataChannel())
```

And the staged photo lane has no production caller at all: `photoLanePort` is
supplied only by tests.

```
src:apps/reference_app/lib/src/chat_demo_controller.dart:34
grep for "photoLanePort:" under apps/reference_app/lib returns nothing
```

## What that does and does not mean

It does **not** mean the numbers are wrong. They measure exactly what they were
built to measure: whether these payload sizes survive a shaped link, on a
transport that does not depend on a loss-reactive control loop. That is the
project's central claim and the measurements support it.

It **does** mean one sentence has to change everywhere it appears. "The six
features were measured end to end on a physical iPhone" is true. "The app was
measured end to end on a physical iPhone" is not, because the app's chat path
is the WebRTC data channel and three of the six features have no production
wiring yet.

The honest form: *the transport and the codecs were measured on a physical
device under a shaped link; wiring those lanes into the application is
in progress.* A reviewer who opens `e2e_matrix_test.dart` reaches that in two
minutes, and it is far better to have said it first.

## The table

```
feature      production path today          measured over        encrypted on the wire

chat text    WebRTC data channel            DatagramLanePort     production: yes, DTLS/SCTP
             (call_session.dart:543)                             measured:   no
news page    not wired in production        DatagramLanePort     no
voice note   token_voice_lane, transport    DatagramLanePort     no
             supplied by the fabric
photo        not wired in production        DatagramLanePort     no
video note   not wired in production        DatagramLanePort     no
push-to-talk not wired in production        DatagramLanePort     no
call media   WebRTC media path              n/a                  yes, DTLS-SRTP
```

Two caveats on the "encrypted" column, both already in `SECURITY.md`. DTLS
protects against an observer on the network, not against the server that
relays the session description, because nothing verifies the fingerprint out of
band. And the datagram lane's encryption is milestone one of the funding
application — it does not exist yet in any form.

## What follows for the beta

The instruction "ship calls and text only, disable the bulk lane" is right, and
this table makes it precise: it means shipping the WebRTC paths and shipping
nothing that rides `DatagramLanePort`. Since three features have no production
wiring anyway, that is less of a subtraction than it sounds.

It also means the beta cannot advertise the measured numbers as what a user
will experience, because a user's chat goes over a different lane than the one
that produced 2.5 seconds. Measure the production path before quoting a figure
to anyone outside the project.

## What this table changes elsewhere

```
README.md                          the device table needs the same distinction
tools/dossier/PROBLEM_STATEMENT.md "measured end to end on a physical iPhone"
tools/dossier/APPLICATION_NLNET.md same sentence, twice
NLNET_SUBMISSION_READY.md          same sentence
PLAN_HARDENING.md                  week 4's pilot must measure the app's path
```

Those are corrected in the same commit as this file.
