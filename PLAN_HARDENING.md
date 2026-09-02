# Hardening plan — what has to be true before anyone at risk installs this

Written 2026-09-02, after a security review found two gaps that were not in
`SECURITY.md` and are more dangerous than the ones that were.

This plan runs alongside the funding application, not after it. They do not
compete: the grant pays for what makes the tool fit for the *next* shutdown —
bulk-lane encryption, the transport core from source, the Android arm, an
independent review. What makes it fit for the *first* one is in this document,
costs no money, and takes about five weeks.

## The rule this plan exists to enforce

A person at risk who installs a tool that protects them from the network but
not from a checkpoint has been given a false sense of protection. That is worse
than having no tool. In January 2026 a Bitchat fork was downloaded 72,000 times
in two days during the blackout and was then found to carry critical
vulnerabilities including two zero-days. We are not repeating that.

So there are two distinct acts, and only the first happens this month:

```
publish a beta          people we know, outside Iran, bugs and measurements
reach users at risk     only after the release gate at the end of this document
```

## What the review found that we had not written down

Two of these were in `SECURITY.md`. Three were not.

```
known    bulk lane carries no encryption of its own
known    signalling server sees who talks to whom, and when
known    nothing verifies the DTLS fingerprint out of band

NEW      private identity keys are not in the platform keystore
         packages/security/lib/src/key_store.dart:60 — "There is no encryption,
         no OS keychain integration, and no..."  Both implementations shipped
         today are InMemoryKeyStore and DevFileKeyStore.
NEW      local application data is plain JSON on disk
         apps/reference_app/lib/src/intelligence/disk_json_storage.dart
NEW      there is no delete-everything action anywhere in the app
         no match for wipeAll / deleteAll / purgeAll under apps/reference_app/lib
```

For most people in the target situation the danger is not someone reading the
wire. It is a phone in someone else's hands. Those last three are therefore
ahead of the fingerprint gap in this plan, even though the fingerprint gap is
the one that sounds worse.

## Week 0 — Wednesday 3 September

Two tracks, and the funding one takes minutes.

```
FUNDING     submit the application — text is in
            tools/dossier/NLNET_SUBMISSION_READY.md
            read the open call's own guide first; the fund the draft was
            written against closed on 1 June and the successor's form may
            differ field for field
            re-scope M1 before submitting: if the safety number ships in
            September it cannot also be a paid milestone, because work
            completed before the agreement is not payable
```

```
ENGINEERING 1  write the lane-per-feature table: which of the six features
               rides DTLS and which rides the unencrypted bulk lane. Nobody
               can reason about the beta without it, including us.
            2  resolve the contradiction between
               tools/cloudflare_relay_worker/README.md (payloads "sealed by
               the client's own session keys") and SECURITY.md (the bulk lane
               has no encryption). secure_media_lane.dart shows "sealed" means
               an anti-replay sequence header. One of those documents is wrong
               and a reviewer will find it before we do.
            3  reconcile security/SECURITY.md, dated July, with the root
               SECURITY.md — they disagree about DTLS-SRTP.
            4  create the Android release signing key offline, back it up in
               two places. A lost signing key means no updates, ever.
            5  apply to Digital Defenders Partnership: up to 10,000 EUR, four
               to six months, and their pages explicitly invite providers of
               secure software. Dutch, small, fast.
            6  book the funder's monthly office hour and ask one question
               directly: is work completed before the agreement payable?
```

verify: `bash tools/phase5/gates/gate_t5_docs.sh` stays green, and the
lane table is committed.

## Week 1 — 4 to 10 September: bind the identity to the session

The gap: DTLS protects the call and text lanes from the network, not from the
server that relays the session description. A signalling server that is
malicious or coerced can substitute fingerprints and sit in the middle.

```
sign the SDP fingerprint plus call id plus role with the identity key
verify on receipt; fail closed on mismatch, never warn-and-continue
tests: substituted fingerprint, replayed signature, wrong role, wrong call id
```

The identity engine, the fingerprint computation and the key-change policy
already exist and are tested in `packages/security` — this is wiring plus a
signature, not a new cryptosystem.

verify: a test that substitutes a fingerprint and asserts the session is
refused. Not a log line — a refusal.

## Week 2 — 11 to 17 September: what the user can check, and where keys live

```
safety number over both parties' long-term identity keys
displayed as digits and as a QR code
scan-to-verify, verified state persisted per contact
re-warn when a key changes, and say what changed
```

Reading a short string aloud mid-call is the fallback for people who cannot
meet, not the primary mechanism: it verifies one session rather than an
identity, and someone under duress can be talked past it.

In the same week, because it is the same file:

```
private keys move to the iOS Keychain and the Android Keystore
DevFileKeyStore stops being reachable from a release build
```

verify: `cd packages/security && dart test` green, plus a test asserting a
release configuration cannot select the development key store.

## Week 3 — 18 to 24 September: the phone, and the address

The checkpoint case:

```
delete-everything action: keys, history, contacts, logs, verified states
at-rest protection for stored data, or store nothing
neutral app name and icon — an app that reads as a protest tool is itself
  evidence in someone's hand
```

The blocking case. Bandwidth is not what breaks first; the address is. Iranian
networks block whole hosting ranges because that is where VPNs live, and this
project has no production relay at all today — `infra/turn/README.md` says local
development only, and the relay hostname is compiled into the app.

The mechanism already exists in outline and is not deployed:
`startup_manifest.dart` accepts a signed manifest from the config layer or out
of band — a scanned QR, a pasted string, a sideloaded file.

```
generate the manifest signing key offline; pin its public key in the build
publish a manifest listing three or more relays on different networks and
  different accounts
publish that manifest in three or more places
prove out-of-band import from a QR code on a real device
```

verify: block the primary relay in a hosts file, import a manifest by QR, and
watch a call connect through the second.

## Week 4 — 25 September to 1 October: a pilot with people who are not at risk

```
10 to 20 people outside Iran, including two or three Farsi-speaking
  digital-security trainers found through a referral
text and voice notes only — the bulk lane is disabled in the build, not
  documented as risky
measurements recorded in the same TSV format as the iOS rows
```

Never recruit activists or journalists directly. A solo developer in the
Netherlands cannot obtain informed consent from someone in Iran about a tool
whose failure mode is arrest. That goes through an organisation with a
duty-of-care process, which is also who should hold the consent.

verify: six end-to-end rows produced by other people's devices, in
`tools/dossier/`, next to the ones the developer produced.

## What every installer must be told, before they install

Plain sentences, in Farsi and English, that cannot be scrolled past.

```
This is a test version. Nobody outside the project has reviewed its security.
Do not use it for anything that could get you or someone else hurt.

Text and calls are encrypted so people watching the network cannot read them.
The server that connects the two phones is not yet something you can check
yourself. If that server were taken over, it could listen in.

The app does not hide that you are using it, who you are talking to, or when.

If your phone is taken, what this app has stored can be read.

Install only from this address: <link>. The file's SHA-256 is <hash>. If the
hash does not match, do not install it.
```

And the words this project does not use, anywhere, until they are earned:
secure · end-to-end encrypted · safe for activists · cannot be intercepted ·
anonymous · censorship-proof · works during shutdowns · tested in Iran.

That last one matters more than it looks. This tool is built for a throttled
and lossy network — two kilobits, sixty percent loss, seconds of latency. It is
not built for a total cut, and saying otherwise would send someone looking for
signal that is not there.

## The release gate

Every line must be true before a build reaches anyone at risk. Not most of
them.

```
[ ] identity bound to the session, mismatch fails closed, tested
[ ] safety number shipped, verifiable by the two people themselves
[ ] private keys in the platform keystore; dev store unreachable in release
[ ] delete-everything action, and at-rest protection or nothing stored
[ ] signed manifest with three or more relays, out-of-band import proven
[ ] Android measured on a physical device — every row today is iOS
[ ] bulk lane either encrypted or absent from the build
[ ] at least one person outside the project has read the identity-binding code
[ ] the install notice above, in Farsi, reviewed by a native speaker who knows
    security vocabulary
[ ] distribution through an organisation that holds consent, not directly
```

Nine of those ten cost time rather than money, which is the whole point: none
of them is waiting on a grant decision.

## Android, specifically

Every device measurement in this repository is from one iPhone. The platform
people in the target situation actually have is Android, shipped here with a
prebuilt `libpt_transport.so` that nobody can rebuild from source. Before an
Android build goes to anyone:

```
six end-to-end rows on a physical Android device of the class people own
the exact commit, toolchain and hash of both .so files recorded beside them
the release signing key created offline and backed up twice
```

F-Droid's main repository builds from source and will not accept the prebuilt
binary, so it is closed to us until the transport core is published — that is
milestone M5 of the application. For the pilot: a signed APK from a release
page, with the hash published on a second channel.

## The funding calendar, running beside all of this

Three applications, three different weeks, three genuinely disjoint sets of
deliverables. That last word is the whole rule: nothing here forbids applying
in more than one place, but the same piece of work may never appear in two
budgets.

```
3 Sep      NLnet, Open Internet Stack      38,700 EUR   the engineering
week of    Digital Defenders Partnership   <10,000 EUR  device security work
  8 Sep
mid-Oct    OTF, Internet Freedom Fund      see below    after the pilot
```

**3 September — NLnet.** Text is ready in
`tools/dossier/NLNET_SUBMISSION_READY.md`. Read the call's own guide first: the
fund this was drafted against closed on 1 June and the successor's form may
differ field for field. Submitting on day one buys no place in a queue —
proposals are reviewed after the deadline, not on arrival — so submit early for
the real reason instead: it leaves time to fix whatever the guide turns out to
require. Deadlines recur on the third of every odd month, so a decline costs
two months rather than a year.

**Week of 8 September — Digital Defenders Partnership.** Up to 10,000 EUR over
four to six months, Dutch, and their pages invite providers of secure software
directly. This is the natural home for the device-hardening work in weeks 2 and
3 of this plan: keystore-backed keys, the delete-everything action, at-rest
protection, and the loaner handsets that let a pilot measure on hardware the
developer does not own.

**Not SIDN, and this is a correction rather than an omission.** Their page
requires a rechtspersoon above 10,000 EUR and lists which forms qualify —
stichting, vereniging, coöperatie, onderlinge waarborgmaatschappij, NV, BV. An
eenmanszaak is on none of them, so only the Pioniers track is open, and that
track funds work relevant to *Dutch* internet infrastructure. Handsets for an
Iran-facing pilot are not that. Applying anyway spends credibility with a
funder who may matter later, for a form that will be declined on eligibility
before anyone reads the engineering.

**Mid-October — OTF, after the pilot has produced evidence.** Not before: their
gate is demonstrated demand, which is precisely why the previous application
there was dismissed. Five weeks of pilot measurements turn that from the
weakest part of the file into the strongest.

On the amount, a correction worth making before it is typed into a form. A
request of 150 to 250 thousand dollars does not match either the instrument or
the applicant. OTF funds projects rather than overhead, and disburses on
completed deliverables with nothing paid up front — so that figure is not money
to receive, it is work to carry unpaid until each deliverable lands. For a solo
developer with no employees, a first contract of 50 to 100 thousand over six to
nine months is what can actually be delivered under those terms, and it sits
inside their own stated range for typical awards.

The shape matters as much as the number. "Global relay servers" is recurring
operational cost, the category they decline. What they do fund, and what this
project can honestly offer: user research with named at-risk communities, and
the relay design published as reproducible infrastructure that others can
deploy — a design and a reference deployment rather than a bill for running a
network.

**What each application says, and what none of them may vary.** The subset of
deliverables, the order, the emphasis and the funder's own vocabulary can
differ. No fact may: how many users exist today, the project's stage, the
licences, the price of any deliverable, where the impact lands, and every
measured number. Two checks while writing — take a sentence from one form and
drop it into another, and if a reviewer holding both would find a factual
disagreement, that is two stories rather than two emphases; and every claim
must resolve to one line in this repository.

**The sentence for the "other funding" field**, wherever it is asked:

```
No past or present funding. A concept note to OTF's Internet Freedom Fund is
planned for [date], for deliverables disjoint from those in this proposal;
nothing is under consideration elsewhere at submission.
```

**No fiscal host.** A Dutch registration and a Dutch account mean NLnet pays
the person directly and OTF contracts with the person directly. An
intermediary would take eight to ten percent for a door that is already open.

**And no probability, anywhere.** NLnet publishes how many projects it selected
and not how many applied, so no acceptance rate can be computed from it. Any
number offered as a chance of success has no source, and a file whose whole
value is that every claim is checkable cannot carry one.

## What this plan does not do

It does not encrypt the bulk lane, publish the transport core from source, or
buy an independent review. Those are the funded milestones and they are
genuinely a season of work, not a weekend.

It also does not promise a date for reaching users in Iran. The gate above
decides that, and the gate is not a calendar.
