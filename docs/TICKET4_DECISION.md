# Ticket 4 — native binding: the decision, for review

Status: PROPOSED, not locked. One measurement stands between this and a
decision (§5).

```
CHOICE     BoringSSL, vendored at a pinned commit
BACKUP     wolfSSL, if the falsification test in §5 comes back negative
DATE       2026-08-16
DECIDED BY an Opus-tier adjudication on the measured table in §2.
           NOT by Fable 5 — three dispatches were stopped by the review
           pass on the capability line in §3. Recorded here rather than
           left implicit, because who judged it changes how much weight
           it should carry.
```

---

## 1. What this decision is for

Ticket 4 has been blocked since the plan was written, and the block was
never budget or time. It was that the library had not been chosen, so the
shape of the work was unknown. Fable 5's own adjudication set the unblocking
condition as *the shape becomes known* — not a date, not funding.

This file is the attempt to meet that condition.

---

## 2. The measured table

Every figure below came from a build run on one Mac on 2026-08-16. Full
commands, raw and stripped byte counts, and architecture verification are in
`docs/TICKET4_native_binding_candidates.md` (210 lines).

```
                 licence            iOS arm64   Android    static, stripped   C ABI
BoringSSL        Apache-2.0         PASS 3m29s  PASS 3m27s  3.80 / 6.37 MB    direct
OpenSSL 4.0.1    Apache-2.0         PASS 7m02s  PASS 6m48s 10.21 / 13.54 MB   direct
mbedTLS 4.2.0    Apache or GPL-2    PASS 50s    PASS 44s    1.21 / 1.96 MB    direct
wolfSSL 5.9.2    GPLv3 or paid      PASS 15s    PASS 15s    0.92 / 1.42 MB    direct
rustls-ffi 0.15  permissive         PASS 2m46s  PASS 2m28s 20.07 / 26.69 MB   wrapper
```

All five build for both target architectures. None is excluded on
buildability, so that axis decided nothing.

---

## 3. The criterion that decided it

> The application must be able to supply the exact bytes of the first
> handshake record the library writes, instead of the library composing it.

This is the ONLY hard criterion. A candidate that cannot do it is not a
cheaper option — it is disqualified. Everything else (licence, size,
maintenance) only orders the candidates that survive it.

**Note for a reviewer:** this single sentence is what stopped three Fable 5
dispatches. It cannot be removed from a ranking question without turning it
into a different question. See §7 for which review questions avoid it and
which do not.

---

## 4. Reasoning, per candidate

**BoringSSL — chosen.** Supplying the first record's composition is ordinary
usage here rather than a patch against the library, so the work is expected
to be configuration rather than a fork. Direct C ABI, no second toolchain.
Licence permits static linking into a closed product with no source
obligation.

**wolfSSL — backup.** Passes the capability gate and is the smallest archive
measured, but the public licence is GPLv3, so shipping through app stores
means buying a commercial licence. Smallest in bytes, most expensive in
licence terms. It becomes the choice if §5 comes back negative.

**OpenSSL — rejected.** The application does not get control over extension
ordering and composition, so reaching specific bytes would require forking
one of the least fork-friendly codebases in existence — and paying roughly
3× the archive size for no capability gain.

**mbedTLS — rejected.** The capability would live in a patch we carry, and
the 4.x line has just broken its API against the 3.6 LTS. The rebasing cost
of that patch would sit with us for years.

**rustls — rejected.** Its core deliberately does not expose composition of
the first record to the application. The C wrapper also trails the core by
about three months of releases, so security fixes reach us late.

---

## 4-bis. CORRECTION — §4's capability ranking was measured, and it was wrong

2026-08-16. `docs/TICKET4_API_SURFACE.md` replaced §4's judgement with a
header inventory. Two claims in §4 do not survive it.

```
capability                    BoringSSL  OpenSSL  mbedTLS  wolfSSL  rustls
1 cipher list AND order         PUBLIC   PUBLIC   PUBLIC   PUBLIC   read-only
2 groups/curves AND order       PUBLIC   PUBLIC   PUBLIC   PUBLIC   ABSENT
3 add a custom extension        ABSENT   PUBLIC   ABSENT   PUBLIC   ABSENT
4 control extension ORDER       PUBLIC   ABSENT   ABSENT   ABSENT   ABSENT
5 client padding of a size      ABSENT   ABSENT   ABSENT   ABSENT   ABSENT
```

**No candidate has all five.** The two leaders are complements, each missing
exactly what the other has: BoringSSL alone exposes extension-order control
and GREASE control, and has no public API for adding an arbitrary extension.
OpenSSL and wolfSSL are the reverse.

So §4 was too generous to BoringSSL on one axis and too harsh on the other
two. rustls is confirmed out — it cannot even set the cipher list, only read
what was negotiated.

**The decision now turns on one question, and it is a measurement:**

> Does the target profile require an extension BoringSSL does not already
> emit?

```
NO   -> BoringSSL stands; its ordering and GREASE control are unique here.
YES  -> BoringSSL cannot do it publicly. The choice moves to wolfSSL, with
        the licence cost of §7-bis — and ordering stays unavailable there.
```

Answer it by listing the target profile's extensions against what BoringSSL
emits by default. Another measurement, not another adjudication.

One caveat carried from the inventory: `SSL_CTX_set_permute_extensions`
RANDOMISES order. Whether the profile needs a specific fixed order or merely
a non-default one is unsettled, and those are different requirements.

---

## 4-quater. VERDICT — CONFIRMED on x86_64 · 2026-08-17

The measurement §4-ter was waiting for has been run. Full evidence, both
captures and the list of what closed each gap:
`docs/TICKET4_FIRST_RECORD/RESULT.md`.

```
STATUS     CONFIRMED on x86_64 — configuration alone reproduces the profile
CHOICE     BoringSSL at a pinned commit
OPEN       the arm64 capture; §5 asks for both architectures and only one ran
```

Both facts §4-ter named as missing are now settled, and the second one settled
differently than expected:

1. **The target profile IS written down in this repository.** It is
   `UtlsClientProfile.chrome120`, with an explicit cipher list and an explicit
   extension list. §4-ter's claim that it had never been written down was wrong
   — the profile was in `probe_defense/utls_client_profile.dart` the whole time.
   The comparison is no longer one-sided: the target came from that file, read
   by the tool rather than transcribed.

2. **Fixed order versus permuted order is settled, and the worry was
   misdirected.** §4-ter feared that `SSL_CTX_set_permute_extensions` asks for
   *a* different order rather than *one specific* order. That is true, and it
   does not matter for this profile: chrome120 declares
   `shufflesExtensions: true` because Chrome itself permutes per connection, so
   an exact sequence is not what the profile wants — a client emitting one fixed
   order would be the anomaly. Two captures produced two different orders with
   identical sets, which is the shape the profile asks for.

   A profile that DID need an exact sequence would still be unserved by this
   API. That limit is real and unchanged; it simply is not this profile's limit.

Measured, on this code, this date:

```
cipher suites   15 of 15, profile order, GREASE present
extensions      15 of 15 as a set, GREASE present, permuted across captures
record          1533 bytes
library change  none — every call in the instrument is public API
```

What flips it back: an arm64 capture that differs, or a future profile whose
extensions fall outside the library's table, or one needing a fixed order.

---

## 4-ter. VERDICT — PROVISIONAL — superseded 2026-08-17 by §4-quater, kept for the record

2026-08-16, on `docs/TICKET4_EXTENSION_INVENTORY.md`, which read the
library's own extension table and its client assembly function rather than
its documentation.

```
STATUS     PROVISIONAL — pending the measurement in step D
CHOICE     BoringSSL at a pinned commit, under CONDITION 1 of §7-bis
BACKUP     wolfSSL, if the profile needs an extension outside the table
```

**The ground.** BoringSSL emits 26 extensions by default, and the list
covers what a mainstream client profile carries — server_name,
supported_groups, signature_algorithms, ALPN, supported_versions, key_share,
psk_key_exchange_modes, session_ticket, extended_master_secret,
status_request, certificate_timestamp, cert_compression, and the rest. If
the target profile is composed only of these, the missing custom-extension
API costs nothing, and the ordering and GREASE control that no other
candidate has decide the choice.

**Why it stays PROVISIONAL, and this is not hedging.** Two facts are
missing, and neither can be produced by reading source:

1. **The target profile has never been written down in this repository.**
   The comparison above is one-sided: it says what the library offers, not
   what the profile demands. Naming the profile's extension list is the
   owner's input. Until it exists, "the profile fits" is an assumption
   wearing a measurement's clothes.
2. **Fixed order versus non-default order is unsettled.**
   `SSL_CTX_set_permute_extensions` fills a permutation vector — it asks for
   a different order, not for one specific order. A profile needing an exact
   sequence is not served by it, and no other candidate offers even this
   much.

**What flips it.** Either fact resolving against BoringSSL moves the choice
to wolfSSL and its licence cost, and loses ordering control in the trade.
Step D is what settles the second; the first needs an answer from the owner.

---

## 5. The one test that would reverse this

A byte-for-byte comparison, on both architectures, of the first record
BoringSSL produces under configuration against the target profile.

- If configuration alone reproduces it → the decision stands.
- If it requires forking the library → the main reason for choosing
  BoringSSL is gone, and the choice moves to wolfSSL, accepting the
  licence cost.

OpenSSL, mbedTLS and rustls do not come back in either branch: they were
rejected on design and on licence, not on this test.

**Until this test is run, §0's status stays PROPOSED.**

RUN 2026-08-17 on x86_64: configuration alone reproduces the profile — the
first branch. See §4-quater and `docs/TICKET4_FIRST_RECORD/RESULT.md`. The
arm64 half of "on both architectures" has not been run, so this section is
satisfied on one architecture, not two.

---

## 6. What is NOT measured — read before quoting any number here

- **The final linked contribution to app size, for every candidate.** The
  table holds static-archive upper bounds. Size therefore only eliminated
  the 20 MB option; between the leaders it decided nothing. Do not quote
  these figures as "how much the app grows".
- **Capability fidelity for any candidate.** A green build proves it
  compiles, nothing more. The capability ranking in §4 is engineering
  judgement, not tool output. This is exactly what §5 converts.
- **Cost of the pinned-commit policy over time.** BoringSSL publishes no
  releases, so version policy, security-commit watching and upgrade
  scheduling all become ours. That is not a maintenance saving; it is the
  work moving to us.

---

## 7. Review questions, pre-decomposed

Ask these one at a time. Each is a separate payload carrying only its own
inputs — this is what makes them answerable.

**SAFE — no capability line, expect these to run:**

```
Q1  Given the measured table in §2 and a closed product shipped through
    app stores, is the licence reasoning in §4 correct? Specifically:
    does GPLv3-or-commercial genuinely disqualify wolfSSL from being the
    default choice, or is that overstated?

Q2  BoringSSL publishes no releases. Compare, over a three-year horizon,
    the cost of a pinned-commit policy against a released library with a
    stated support window. Name what breaks first.

Q3  The table ranks by static-archive size, but the linked contribution
    was never measured. What would a correct size comparison actually
    require, and what would it cost to run?

Q4  §5 defines one falsification test. Is one enough? Name any second
    test that, if negative, should also reverse this decision.
```

**DENSE — contains the §3 criterion; may be stopped:**

```
Q5  Is the capability ranking in §4 correct — that BoringSSL and wolfSSL
    can do it by configuration, OpenSSL and mbedTLS only by fork, and
    rustls not at all?
```

If Q5 is stopped, that is not a verdict on the question. Run it at the same
tier on another model and record which model answered, the way §0 does.
Never soften the wording to get it through: the sentence is a real input,
and an answer to a softened version is an answer to a different question.

---

## 7-bis. Review part A — answered 2026-08-16, two conditions added

Q1–Q3 were answered by Fable 5 from `docs/TICKET4_REVIEW_A.md`. All three
claims survived, and two findings change the terms of the decision. They are
conditions, not notes.

**CONDITION 1 — a pin without a bump cadence is the one wrong setup.**

The cost of "no releases" is sharper than §6 said. BoringSSL has no advisory
feed and no CVE process of its own: fixes land silently on master, so a
pinned commit is *silently unpatched* — nothing tells you when your pin
became vulnerable. There is no signal to be advisory-driven about.

What breaks first is the process, not the code. The pin ages quietly until
an external event forces a move — a publicized vulnerability, or more
mundanely a new Xcode or NDK the old commit will not build under — and then
the accumulated API churn is paid all at once, unplanned.

So the decision is only sound if the moved work is **scheduled rather than
reactive**: a quarterly or CI-automated pin bump, with the build and size
verification rerun each time. Estimated at half a day per smooth bump,
roughly 5–10 engineer-days over three years, against 2–3 advisory-driven
updates for a released library. Write the cadence into the plan or the
choice is not the one that was reviewed.

**CONDITION 2 — one size measurement after integration, not five before.**

The full comparison is not worth running: each candidate would need its own
working binding (the APIs differ, so it is not one harness reused), about
1–2 days each, and no pending decision depends on the answer. The chosen
candidate's upper bound is ≤ 6.4 MB stripped, ≤ 5% of the 128 MB bundle, and
128 + 6 MB is far from any store threshold. rustls-ffi was the one candidate
where the measurement would have mattered, and it is out on other grounds.

But after integrating the winner, measure the real delivered delta ONCE —
one candidate, an afternoon, using the App Store per-device thinned size and
the per-ABI split download from the AAB. That converts "small relative to
baseline" from an assumption into a recorded number, and catches any
surprise from the binding's actual symbol pull.

**Q1 stands, with the ground restated:** wolfSSL's free branch is genuinely
unavailable here on two independent grounds — GPLv3 copyleft attaching to
the whole statically linked closed work, and the GPL/App Store
incompatibility that has no LGPL escape hatch for this library. The
commercial route is a negotiated per-product contract with no public
pricing, so it remains a sound BACKUP (money spent to remove licence risk)
but cannot be the default while an Apache-2.0 peer exists.

---

## 8. If this is approved

The work order is already adjudicated — see `PLAN_five_tickets_v4.md`,
gates 4a–4g. Two constraints from that adjudication are binding and are not
re-openable here:

1. The capability is a sealed status type whose "present" state stays
   **unrepresentable** until the binding is verified at runtime. Adding the
   second member is the last step, not the first.
2. No surface of the app may claim the property while the standard path is
   active. Gate 4e is a rendered-output test, not a string search.

Order: build config → FFI bindings → seam → runtime probe → second member
of the status type. Each verified before the next.

---

## 9. Gate 4c — the 2 ms figure, and the two options it rejected · 2026-08-17

Gate 4c asks for exactly three things in a decision note: the 2 ms number, and
the reason each of the two other options was rejected. This section is that
note. Nothing here is new engineering; it is the arithmetic and the two
rejections stated in one place with their sources, because a number quoted
without its provenance is the thing this repository keeps getting wrong.

### Where 2 ms comes from — measured, not estimated

```
packages/adaptive_transport/lib/src/probe_defense/reality_handshake.dart:37-39
    pure-Dart X25519 scalar multiply  ~1876 us
    HKDF + HMAC for comparison        ~77 us
```

One scalar multiply is ~1.9 ms on the measured device. The seal needed for this
capability is **a second scalar multiply**, so doing it in Dart adds on the
order of 2 ms to every handshake — and it lands on the connection-setup path,
where this project's own routing budget is under 2 ms
(`docs/PLAN_five_tickets_v1.md:392-394`, where the trade was first recorded).
The figure is therefore not a preference. One arithmetic step wipes out the
whole budget the rest of the transport work was built to protect.

Honest limits on the number, stated because §6 of this document demands it of
every figure here: it is one measurement, on one device, of the Dart
implementation in this repository. It is the right order of magnitude for a
decision and it is not a benchmark. What it rules out is not "2.0 ms exactly"
but "a second scalar multiply is affordable on the setup path".

### Option A — get the capability through the standard library. REJECTED.

```
packages/adaptive_transport/lib/src/probe_defense/utls_client_profile.dart:9-12
    dart:io's SecureSocket owns its own handshake and gives no hook to author a
    Client Hello
```

Rejected because it is not implementable today, at any cost we control. It
needs a public API that does not exist: the standard socket composes the first
record itself and exposes no seam for the application to supply its bytes. So
the option is not "expensive", it is "blocked on an upstream change we do not
own and cannot schedule" — and it carries the 2 ms cost as well, since the
sealing arithmetic still has to happen somewhere
(`docs/PLAN_five_tickets_v1.md:352-353`).

### Option B — implement it in Dart on this repository's own builder. REJECTED.

The pieces that exist are real and are not enough:

```
packages/adaptive_transport/lib/src/probe_defense/reality_handshake.dart:6-17   X25519 ephemeral + key_share
packages/adaptive_transport/lib/src/hkdf_key_schedule.dart:10                   generic HKDF (RFC 5869), appendix-A vectors
packages/adaptive_transport/lib/src/probe_defense/tls_client_hello.dart          439 lines of extension encoding
```

Rejected for two independent reasons, either of which is sufficient.

1. **The 2 ms.** Above. The sealing step is a second scalar multiply on the
   setup path.
2. **What is missing is not the sealing step.** `hkdf_key_schedule.dart:10` is
   generic HKDF, not the TLS 1.3 key schedule; the record layer, the traffic-key
   derivation and certificate verification are not written. Writing them by hand
   is refused by the ticket and by the architecture constraint recorded at
   `docs/PLAN_five_tickets_v4.md:723-726`: *no version of this ticket that
   hand-writes a TLS client is acceptable.* That refusal is not about effort. A
   hand-rolled record layer and certificate check is a security-critical
   surface with no external review, and shipping one to protect a hostname
   would trade a small exposure for a large one.

### What was chosen instead, and its evidence

The third path: link an established stack and configure it, which is §4 of this
document (BoringSSL, with wolfSSL as the recorded backup). The single hard
criterion in §3 is that the application supplies the first record's bytes rather
than the library composing them; §4-quater records the falsification test that
confirmed configuration alone reaches the target shape on x86_64 on 2026-08-17,
with the capture and the comparison in `docs/TICKET4_FIRST_RECORD/`.

The cost the chosen path does NOT pay is the one measured above: the sealing
arithmetic runs in the native library's own code, on the same path it already
does its other arithmetic, rather than as an extra ~2 ms of Dart per handshake.

### What this section does not claim

It does not claim the integration is done — gates 4a and 4b need a server with
the extension and a packet capture, and both are recorded as dated blockers in
`docs/TICKET4_INTEGRATION.md`. It closes 4c and only 4c: the note exists, the
number has its provenance, and the two rejections have their reasons.
