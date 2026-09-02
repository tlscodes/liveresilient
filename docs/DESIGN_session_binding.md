# Binding the identity key to the session

Design for `PLAN_HARDENING.md` week 1. Reviewed 2026-09-02. Not implemented.

The gap: DTLS protects the media path and the text data channel from an
observer on the network. It does not protect them from the party that relays
the session description. A signalling server that is malicious or coerced can
substitute the DTLS fingerprint in transit and terminate both legs itself.

## What the review changed before any code was written

Four facts from the codebase that make the naive version wrong.

**Nothing carries a peer's identity public key today.** No code outside
`packages/security` calls `checkRemoteIdentity` or `localKeyId()`. Signal
envelopes are unsigned and `senderKeyId` is a bare claim — the reference app
sets it to the literal `'${role.name}-key'`. So this is not "wiring plus a
signature": the 32-byte public key has to travel in the offer/answer payload,
and a `peerId` has to be chosen.

**`verifySessionFingerprint` cannot do first contact** — it returns false for
an unpinned peer. The order must be verify against the key that was presented,
then pin, never the reverse.

**`signSessionFingerprint` signs raw caller bytes with no domain tag,** while
the same identity key signs local-link envelopes prefixed `ae-v1`. Two
different message types under one key with no separation is a cross-protocol
signature-reuse hazard. Neither primitive survives into this design.

**Peer connections get no `certificates` entry,** so the DTLS certificate is
ephemeral per PeerConnection. That is load-bearing for replay safety below and
must never change; it gets its own test.

## The signed message

Length-prefixed fields — u32 big-endian length, then bytes — so boundaries are
unambiguous and `("ab","c")` cannot collide with `("a","bc")`.

```
1  "vck-session-binding-v1"   ASCII domain tag, distinct from "ae-v1"
2  callId                     UTF-8, exactly the envelope callId, unnormalised
3  signerRole                 "initiator" | "receiver"
4  descriptionType            "offer" | "answer"
5  fingerprintAlgorithm       "sha-256", lowercase, the only accepted value
6  fingerprint                32 raw bytes
7  signerPublicKey            32 raw Ed25519 bytes
```

Field 7 makes the signature commit to the key that verifies it. There is no
timestamp and no nonce, deliberately: freshness is not what defeats replay here,
and a clock introduces a failure mode that looks exactly like an attack.

## Parsing the fingerprint out of SDP

Every `a=fingerprint:` line, session level and each media section, CRLF or LF,
trimmed. Split on the first space. Lowercase the algorithm and require
`sha-256`. Strip colons, lowercase, require 64 hex characters, decode to 32
bytes. If several lines exist every decoded value must be byte-identical.
Any disagreement, any non-sha-256 line, or none at all means the description is
invalid and is refused. Compare as bytes, never as strings.

## On the wire

```json
{ "type": "offer", "sdp": "...",
  "binding": { "v": 1, "alg": "ed25519", "fpAlg": "sha-256",
               "fp": "<64 lowercase hex>", "role": "initiator",
               "pk": "<base64, 32 bytes>", "sig": "<base64, 64 bytes>" } }
```

The sender attests after `setLocalDescription` and before the send, signing the
description object it is actually sending. Every description is attested
separately — recovery can restart the media session and produce a new
certificate under the same call id, so there is no such thing as "the
fingerprint of the call".

## What the receiver checks, in order

Nothing is pinned until step 6 passes. Every failure is a refusal with its own
reason; none is a silent drop.

```
1  structural: binding present, v==1, alg and fpAlg as specified, pk 32 bytes,
   sig 64, fp 32, role a known value      -> missingBinding | malformed
2  pk is not our own public key            -> reflected
3  role is the opposite of ours            -> roleMismatch
4  the SDP's fingerprint parses            -> sdpFingerprintInvalid
5  attested fp equals the SDP's fp         -> fingerprintMismatch   (substitution)
6  rebuild from OUR callId and verify      -> badSignature          (forgery)
7  checkRemoteIdentity(peerId, pk)
       first use -> proceed, flagged not yet verified
       match     -> proceed
       changed   -> identityChanged, refuse, keep the key for the UI
8  only now emit the remote description
```

Step 6 uses the adapter's own call id, never one read from the payload.

## Why replay and splicing fail

The certificate's private key exists only inside the legitimate peer's live
PeerConnection. A replayed attestation — from an earlier call, or from before a
recovery restart — commits to a fingerprint whose private key the server does
not hold, so DTLS cannot complete. Replay is therefore at worst denial of
service, which the server already has. The call id and description type are
bound anyway so those tests are crisp, and the role plus check 2 stop
reflection.

That argument depends on certificates staying ephemeral. It is written as a
comment at the parser and as a test asserting the connection config never
carries a `certificates` entry.

## What this buys, stated narrowly

On a first contact with nothing exchanged out of band: the session is bound to
some identity key whose holder proved possession, that key is pinned, and a
server that inserts itself must substitute its own key on that call and every
later call with that contact — the pin fires the first time it stops.

It does not tell A that the person behind the pinned key is B. On first contact
a server can connect A to C under B's name, and A's pin will hold C's key. The
safety number in week 2 is what exposes that, retroactively and at any time.

So the mechanism never produces the word "verified" on its own. The three
states a user sees:

```
Encrypted — identity not yet verified. Compare safety numbers to confirm.
Verified                     only after an out-of-band comparison
Safety number changed        refused, with what changed and when
```

## Failing closed

Fail closed with no exception. It adds nothing to a hostile server's power — it
can already drop the envelope — so the only thing a softer mode changes is what
the user is told, and "warn and continue" hands content to the attacker before
the warning is read.

The broken-versus-attacking distinction is structural rather than heuristic. A
broken server produces absence, malformation or silence. A server presenting a
well-formed binding that fails step 5 or 6 had to construct it. Show the reason
with a retry that re-runs the whole handshake: transient corruption heals, a
persistent attack stays visible. Count failures locally, never report them to
the server, which is the adversary.

No compatibility path for peers that send no binding. That is the same attack
as a downgrade — the server simply strips the field. There are no released
users before the pilot, so the binding is mandatory from the first build.

## What the keys being in a plain file does to this

The signature is exactly as strong as the seed's confidentiality. The adversary
being closed here is the server, which does not have the file, so the value
against the server is full and the value against device compromise is nil —
unchanged from today. The construction does not differ before and after the
keystore lands, because the storage seam already isolates it.

Note for the same week: an Apple Keychain adapter already exists in
`packages/security_keychain` and nothing imports it. Wiring it is small. Even
then the honest phrase is "encrypted at rest by the OS", not "hardware-backed
signing", because the seed remains extractable.

## Key change

Reinstall and attack are indistinguishable at the protocol level and the design
does not pretend otherwise. On a change: refuse the session terminally, show
whose safety number changed, and offer exactly two actions — compare the new
number and accept, or decline. Never auto-accept, never on a timer, never
because the same new key appeared twice.

Persisted per peer, replacing today's bare hex string: the pinned key, when it
was pinned, whether it was verified out of band and how, and a bounded history
of previous keys with change times so the interface can say "changed on this
date, was verified before". Locally, a flag saying the user's own identity was
regenerated, so they are told once that their contacts will see a change.

## Tests the implementation must pass

```
fingerprint parser   session-level, media-level, both equal, CRLF and LF,
                     case and colon variants, disagreeing lines, sha-1,
                     absent, 63 and 65 hex characters
canonical message    a golden vector committed in the test; the boundary case
                     ("ab","c") vs ("a","bc"); an ae-v1 signature never
                     verifies here
sign and verify      round trip; one nibble of fp changed both ways; wrong
                     call id; wrong role; offer attested and answer received;
                     own key presented; pk not the signer; wrong-length pk,
                     sig and base64 all refuse without throwing; an
                     attestation for one fingerprint delivered with another;
                     a whole pair from call A delivered in call B
pinning order        invalid signature leaves the store untouched; first
                     valid pins; second matches; a new key is refused;
                     accepting the change then matches
adapter              a gateway that substitutes the fingerprint ends the call
                     terminally, never enters recovery, and the fake media
                     never receives a remote description; a gateway that
                     strips the binding does the same with its own reason;
                     glare; a recovery restart re-attests
config               the connection config carries no certificates entry
```

## What the plan underestimated

Scope. The cryptography is a signature over a canonical message, but the wiring
touches five packages — security, call core, the signalling adapter, the WebRTC
config test and the reference app — plus two threat-model rows. Week 1 is the
right size for the crypto and optimistic for the wiring.

Two more things to fix while here. `peerId` must not be derived from the key,
or every new key looks like a first use and key change becomes undetectable by
construction; until real addressing exists, pin under the address dialled and
say so in the code. And the safety-number derivation planned for week 2 hashes
a hex string's code units and takes digits by byte modulo ten, which is
slightly biased — freeze it with a golden vector and a version byte before any
user sees one, because it can never change afterwards.

ICE candidates stay unauthenticated. That is acceptable, since they affect
routing only and DTLS still authenticates the certificate, but it belongs in
the threat model rather than left implicit.
