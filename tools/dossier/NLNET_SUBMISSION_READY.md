# NLnet submission — one field per heading, ready to paste

Everything below is final text. Paste each block into the field with the same
name, in order.

Two things to do before you paste anything, both of which take minutes:

```
1  Open the call's own guide. The fund this was first written against closed on
   1 June 2026; the successor opened 3 September. If a field below has no
   counterpart in the form, drop it. If the form asks something not here, the
   answer is in tools/dossier/APPLICATION_NLNET.md.
2  Confirm the ceiling still reads 50,000 EUR for a first proposal. If it has
   moved, the budget below still stands — it was built from the work, not from
   the ceiling.
```

---

## Project name

```
LiveResilient
```

## Website / repository

```
https://github.com/tlscodes/liveresilient
```

## Abstract

```
When a network is throttled rather than cut, people are left with a few
kilobits per second, heavy packet loss and seconds of latency. Ordinary
messengers fail there — not because the link is dead, but because they assume a
working congestion-control loop and enough bandwidth to finish an upload.

LiveResilient is a calling and messaging kit built for that floor. Bulk content
travels as rateless coded symbols over plain UDP, so loss costs proportional
extra symbols instead of a stalled round trip, and every feature has a wire
budget proven by a gate rather than asserted.

Six features - text, a news page, a photograph, a voice note, a short video
note and live push-to-talk - fit between 29 and 5,926 bytes, and all six have
been measured end to end on a physical iPhone over a shaped link. A 4 MiB
transfer that never completed at all on a reliability-managed channel at 60%
loss completed and hash-verified in 303 seconds on the coded lane. Everything
is public: Apache-2.0 for the client and packages, AGPL-3.0 for the server,
with continuous integration green on infrastructure that is not the developer's
machine.

The result is interoperable by construction rather than by promise: standard
WebRTC for media, plain UDP underneath the coded lane, no proprietary service
in the path, and no dependency on a platform any single vendor controls.
```

## Have you been involved with projects or organisations relevant to this before?

```
This is a solo project by a developer registered in the Netherlands as Living
Stone Apps. It has no institutional backers, no users and no letters of
support, and this application does not ask you to take any of those on trust.

What exists instead is a public record of the engineering. The repository holds
the transport matrix as an append-only log including every failed run, the
codec gate logs, the device measurements, and a manifest recording the size and
hash of each artifact so a reviewer can confirm that the file they are reading
is the file that was measured - a continuous integration job verifies those
hashes on every push.

Where a result is weaker than its label suggests, the documents say so first.
The push-to-talk row is judged on liveness rather than continuity, and it says
so in the results file, in the README and in the test itself.
```

## Requested amount

```
38700
```

## Explain what the requested budget will be used for

```
38,700 EUR - 740 hours at 50 EUR/hour plus 1,700 EUR of receipted costs, over
twelve months at roughly fifteen hours a week.

The rate is your own published convention rather than a market average: 65
EUR/hour is the stated ceiling and the guidance warns that using the ceiling
costs cost-effectiveness score. Fifty sits below it, below the Commission's own
daily unit cost for an SME owner without a salary, and near half the Dutch
freelance software rate. There is no contingency line: no overhead is paid, so
risk belongs in the hours.

  M1  datagram-lane encryption      160 h                8,000
  M2  security review and answers   100 h + review        5,000
  M3  push-to-talk continuity       150 h                7,500
  M4  supervised pilot              130 h + 1,700 EUR    8,200
  M5  transport core from source    120 h                6,000
  M6  Android arm of the pilot       80 h                4,000
                                    740 h               38,700 EUR

M1 - end-to-end encryption on the bulk lane, 160 h. The lane carrying bulk
content on lossy links has no encryption of its own, which SECURITY.md states
plainly. A standard construction, a Noise-pattern handshake with a standard
AEAD, not a bespoke cipher. One awkward consequence is stated rather than
hidden: an authentication tag plus a nonce on a 29-byte text gate is more than
half its size again, so either a budget is renegotiated with the overhead
recorded or the design justifies implicit nonces and a shorter tag. Twenty-four
of the hours exist for that reconciliation. This milestone also closes a second
gap: nothing currently verifies the DTLS fingerprint out of band, so a
signalling server that is malicious or coerced can substitute fingerprints on
the call and text lanes. The fix is a safety number over both parties' identity
keys, shown as digits and a QR code.
Acceptance: the six transport matrix rows re-run with the layer in place and
the measured overhead recorded in the results file.

M2 - independent security review and the work to answer it, 100 h plus the
review. The project has never been audited. Scoped to the two gaps named above
rather than the whole codebase. If a programme audit slot is available the line
is not spent.
Acceptance: the report published in the repository alongside the commits that
answer each finding.

M3 - push-to-talk continuity, 150 h. The live voice lane survives the hardest
profile but delivered 10 of 60 bundles with a 40.7-second gap on the recorded
run, and today's rule only checks that the lane stayed alive. The bar this
milestone must meet, written down now rather than after the fact: at the
60%-loss profile, on a physical device, at least 48 of 60 bundles delivered and
a longest gap of 3.0 seconds or less.
Acceptance: that bar, met on a physical device, replacing the liveness-only
rule in the test.

M4 - supervised pilot, 130 h and about 1,700 EUR. Recruiting and onboarding six
to eight testers, distribution and signing, an in-app runner so testers produce
the six rows themselves, supervised sessions, and fixes for what breaks on
other people's hardware. The receipted line is the developer programme fee,
prepaid data for impaired-link sessions, a small server for the signalling
service during the pilot, and four loaner handsets. On the handsets: your policy
excludes basic operational equipment - laptops, workstations, phones - and this
application requests none of it. It permits hardware directly necessary for the
project's tasks, and this milestone's acceptance test requires measurements on
devices that are not the developer's, from volunteers who cannot be asked to
own a particular model. Four mid-range devices at about 300 EUR each, each with
a receipt, returned to the pool at the end.
Acceptance: the six end-to-end rows reproduced on testers' own devices.

M5 - the transport core, buildable from source, 120 h. The Darwin transport
framework and two Android shared objects ship as prebuilt binaries. SECURITY.md
records that a reader cannot reproduce them from this repository, and it is the
weakest point in a repository that otherwise invites verification: everything
can be checked except the layer nearest the network. Publishing the engine
under the same licence, giving it its own build in CI across three platforms,
making those builds reproducible, and wiring the kit to build against source.
Acceptance: a CI job that builds the transport core from published source on
each target platform, and a provenance record mapping every shipped binary to
the commit and toolchain that produced it.

M6 - the Android arm of the pilot, 80 h. Every device measurement so far comes
from one iPhone. A pilot reachable only by iOS owners has a hardware
prerequisite most people in the target condition do not have.
Acceptance: the six end-to-end rows recorded on Android devices in the same
results file, under the same profile, beside the iOS rows.

Every milestone follows the pattern the repository already uses: a verify
command that exits zero, and no milestone reported complete without it. The six
amounts sum exactly to the requested total.
```

## Does the project have other funding sources, past or present?

```
None. The project is self-funded and no hours to date have been paid, by this
programme or any other, past or present. No application is under consideration
elsewhere at the time of submission; a concept note to the Open Technology
Fund's Internet Freedom Fund is planned for a later date, for deliverables
disjoint from those above.
```

## Compare your own project with existing or historical efforts

```
Delay-tolerant and mesh projects - Briar, Serval, the DTN line of work - solve
the case where there is no infrastructure at all, using local radio or
store-and-forward between devices. This project addresses the different and
more common case: infrastructure exists and is reachable, but the link it gives
you is too poor for software that assumes a healthy one.

Against mainstream messengers the difference is measurable rather than
philosophical: the same transfer, the same shaped link, one that never
completes and one that completes and verifies. Against low-bitrate codec work
such as Codec2, this project is a consumer rather than a competitor - the
contribution is the budget discipline and the transport around it, not the
vocoder.

Rateless coding is decades old and no novelty is claimed for it. What is new is
the combination held to a measured floor: coded transport, a wire budget per
feature, and the whole thing demonstrated on real hardware.
```

## What are the significant technical challenges you expect to solve?

```
Encrypting the bulk lane without giving back the loss tolerance that justifies
it, since a handshake needing a reliable round trip reintroduces the failure
the lane exists to avoid.

Making the identity binding verifiable by the two people talking rather than by
the server relaying them, which is what a safety number over long-term keys
buys and what its absence currently costs.

Establishing a continuity bar for live voice that is honest at 60% loss: high
enough to mean something, low enough to be reachable.

Deriving the lane's parameters from measured link conditions rather than
constants calibrated on one network - a mistake this project has already made
once and fixed.

Reproducing device results on hardware the developer does not own, which is
where most single-machine projects turn out to have been measuring their own
machine.

And one that is smaller than it sounds but gets permanently more expensive the
longer it waits: the signed formats this project ships carry no algorithm
identifier, so no cryptographic migration can ever be done safely, whatever the
reason for migrating turns out to be. Adding those identifiers costs a few
bytes now and a flag day after deployment. The design is written up in
docs/CRYPTO_AGILITY_AND_PQ_READINESS.md, which is explicit that it is a
proposal and not implemented - no post-quantum capability is claimed here.
```

## Describe the ecosystem of the project, and how you will engage with stakeholders

```
Honest position first: there is no community around this yet. The repository
became public in September 2026 and has no external contributors.

The plan is to earn one rather than announce one. The first approach is to
digital-rights organisations that document network shutdowns - not for
endorsement, but to have the threat model and the pilot design reviewed by
people who talk to affected users. The security review milestone brings a
second set of outside eyes with a published report. The transport lane and the
codec bindings are the parts most reusable by others, and they are packaged so
they can be taken without the application around them.

On interoperability, which this programme cares about specifically: the media
path is standard WebRTC, the coded lane runs over plain UDP, there is no
proprietary service anywhere in the path, and no component depends on a
platform a single vendor controls. Someone can adopt the transport without
adopting the application, and someone can run the server without asking anyone
for permission - it is AGPL-3.0, so running a modified one as a service means
publishing the changes.
```

## Attachments and links

```
Repository          https://github.com/tlscodes/liveresilient
Problem statement   tools/dossier/PROBLEM_STATEMENT.md
Measurements        tools/dossier/manifest.tsv - path, size and hash per file
Known gaps          SECURITY.md
Continuous integration, green, all jobs: tag v0.1.0-ci-green
```

## Did you use generative AI in preparing this proposal?

```
Yes. This project was built and this proposal drafted with heavy use of an AI
coding assistant, and the repository makes that visible rather than hiding it:
the planning documents, session notes and review prompts are committed
alongside the code.

Every design decision, every measurement and every acceptance criterion is
mine. Every number in this application traces to a committed artifact rather
than to a model's recollection, and a lint in the repository enforces that rule
on the documents it came from. Where a figure could not be traced, it was cut
rather than softened - including two engineering numbers that had been carried
forward in prose and turned out to exist in no results file.
```

---

## What is deliberately not in this submission

Two things were suggested and left out on purpose, so that nobody adds them
later without knowing why.

**No post-quantum claim.** The vocabulary fits the programme, and the project
has an honest document about it, but that document's own first line says it is
a design proposal and not implemented. A capability claimed in a funding form
and absent from the code is the one failure that costs an application its
credibility entirely. What is true - crypto-agility, and why it gets more
expensive every day it waits - is in the technical challenges answer instead.

**No tax structuring.** The form asks what the budget buys, not how the
applicant books it. A statement about BTW treatment or income-tax deduction is
a tax assertion nobody here has verified, and the programme states plainly that
it gives no tax advice and that the grantee owes any tax due. That question is
worth one hour with a Dutch accountant before signing anything, and it is
recorded in the private applicant notes - not in a document a reviewer scores.
