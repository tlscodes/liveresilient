# NLnet submission — one field per heading, ready to paste

Everything below is final text. Paste each block into the field with the same
name, in order.

Read from the form itself on 2026-09-07:

```
deadline    3 November 2026, 12:00 CET (noon)
ceiling     50,000 EUR for a first grant — unchanged
attachments none required; two optional uploads, 50 MB each
field 1     "Select a fund" is a dropdown and is the form's FIRST question.
            No block below answers it: that choice is the owner's, and it
            decides which scope every answer is read against.
```

Every block below whose field declares a `maxlength` carries it as a
`FIELD LIMIT` comment. `python3 tools/dossier/field_length_gate.py` measures each
one and exits non-zero when a block outgrows its field — a browser truncates an
over-long paste silently, keeping the opening characters and discarding the rest
with no warning. If the form asks something not here, the answer is in
`tools/dossier/APPLICATION_NLNET.md`.

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

<!-- FIELD LIMIT 1000 characters — form field "Project summary", maxlength read
     from https://nlnet.nl/propose/ on 2026-09-07. Checked by
     tools/dossier/field_length_gate.py, which measures 997 here, counting the
     trailing newline because whether a paste carries it depends on how the
     text is selected. The browser truncates silently: the previous
     1652-character version lost the 4 MiB result, both licences and the CI
     line, with no warning of any kind. -->

```
Throttled networks leave a few kilobits per second, heavy loss and seconds of
latency; ordinary messengers stall there. LiveResilient is a calling and
messaging kit built for that floor: bulk content travels as rateless coded
symbols over plain UDP, so loss costs extra symbols, not a stalled round trip.
Six features (text, news page, photo, voice note, video note, push-to-talk) fit
between 29 and 5,926 bytes, measured on a physical iPhone over a shaped link. A
4 MiB transfer that never completed on a reliability-managed channel at 60%
loss completed and hash-verified in 303 seconds on the coded lane. Those
numbers characterise the transport; not every lane is wired into the app yet.
Client and packages are Apache-2.0, the server AGPL-3.0, and CI runs green on
infrastructure that is not the developer's machine. Media is standard WebRTC,
the coded lane plain UDP; the relay protocol is documented and swaps with one
hostname, though the default deployment runs on a commercial platform.
```

## Have you been involved with projects or organisations relevant to this before?

<!-- FIELD LIMIT 2000 characters — form field "Applicant background/experience", maxlength read
     from https://nlnet.nl/propose/ on 2026-09-07. Checked by
     tools/dossier/field_length_gate.py; a browser truncates an over-long
     paste silently. -->

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

<!-- FIELD LIMIT 4000 characters — form field "Budget breakdown", maxlength read
     from https://nlnet.nl/propose/ on 2026-09-07. Checked by
     tools/dossier/field_length_gate.py; a browser truncates an over-long
     paste silently. -->

```
38,700 EUR: 740 hours at 50 EUR/hour plus 1,700 EUR of receipted costs, over
twelve months at about fifteen hours a week.

50 EUR/hour is below the 65 EUR/hour ceiling in your guidance and near half
the Dutch freelance software rate. No overhead or contingency; risk is carried
in the hours.

  M1  datagram-lane encryption      160 h                8,000
  M2  security review and answers   100 h                5,000
  M3  push-to-talk continuity       150 h                7,500
  M4  supervised pilot              130 h + 1,700 EUR    8,200
  M5  transport core from source    120 h                6,000
  M6  Android arm of the pilot       80 h                4,000
                                    740 h               38,700 EUR

M1 - end-to-end encryption on the bulk lane, 160 h. The bulk lane has no
encryption of its own; SECURITY.md says so. Noise handshake plus a standard
AEAD, no bespoke cipher. Its cost is known: type, replay counter and tag add
25 bytes per frame, nearly doubling the 29-byte text gate; 24 of the hours
reconcile that, by renegotiating the gate with the overhead recorded or by
earning bytes back with an implicit nonce and a tag length justified against
the threat. A second gap is disclosed and not billed: nothing yet verifies the
DTLS fingerprint out of band, so a coerced signalling server could swap
fingerprints. A safety number over both identity keys, compared outside its
reach, is being built now, unpaid. Acceptance: the six transport matrix rows
re-run with the layer in place and the measured overhead recorded in the
results file.

M2 - independent security review and the work to answer it, 100 h. The project
has never been audited. The review is requested as a programme audit slot, no
fee here; the hours answer it, scoped to the two gaps above. Acceptance: the
report published in the repository beside the commits that answer each
finding.

M3 - push-to-talk continuity, 150 h. On the recorded run at the hardest
profile the live voice lane delivered 10 of 60 bundles with a 40.7-second gap;
today's test checks only liveness. Acceptance: at the 60%-loss profile on a
physical device, at least 48 of 60 bundles delivered and a longest gap of 3.0
seconds or less, replacing the liveness-only rule in the test.

M4 - supervised pilot, 130 h and 1,700 EUR. Six to eight testers, signed
builds, an in-app runner so testers produce the six rows themselves,
supervised sessions, and fixes for what breaks on their hardware. Receipted:
the developer programme fee, prepaid data for impaired-link sessions, a small
signalling server for the pilot, and four loaner handsets. The handsets are
not the developer's equipment, which your policy excludes, but hardware
directly necessary to the task: the acceptance test needs devices that are not
the developer's, from volunteers who cannot be asked to own a particular
model. Four mid-range devices at about 300 EUR each, receipted, returned to
the pool at the end. Acceptance: the six end-to-end rows reproduced on
testers' own devices.

M5 - the transport core, buildable from source, 120 h. The Darwin transport
framework and two Android shared objects ship as prebuilt binaries that
SECURITY.md admits a reader cannot reproduce: the one unverifiable layer.
Publish the engine under the same licence, build it reproducibly in CI on
three platforms, and build the kit against source. Acceptance: a CI job that
builds the transport core from published source on each target platform, and a
provenance record mapping every shipped binary to the commit and toolchain
that produced it.

M6 - the Android arm of the pilot, 80 h. Every device measurement so far is
from one iPhone; an iOS-only pilot has a hardware prerequisite most people in
the target condition lack. Acceptance: the six end-to-end rows recorded on
Android devices under the same profile, beside the iOS rows.

Every milestone closes as the repository already does: a verify command that
exits zero.
```

## Does the project have other funding sources, past or present?

<!-- FIELD LIMIT 1000 characters — form field "Other funding sources", maxlength read
     from https://nlnet.nl/propose/ on 2026-09-07. Checked by
     tools/dossier/field_length_gate.py; a browser truncates an over-long
     paste silently. -->

```
None. The project is self-funded and no hours to date have been paid, by this
programme or any other, past or present. No application is under consideration
elsewhere at the time of submission; a concept note to the Open Technology
Fund's Internet Freedom Fund is planned for a later date, for deliverables
disjoint from those above.
```

## Compare your own project with existing or historical efforts

<!-- FIELD LIMIT 4000 characters — form field "Comparison with other efforts", maxlength read
     from https://nlnet.nl/propose/ on 2026-09-07. Checked by
     tools/dossier/field_length_gate.py; a browser truncates an over-long
     paste silently. -->

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

<!-- FIELD LIMIT 4000 characters — form field "Technical challenges", maxlength read
     from https://nlnet.nl/propose/ on 2026-09-07. Checked by
     tools/dossier/field_length_gate.py; a browser truncates an over-long
     paste silently. -->

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

<!-- FIELD LIMIT 2000 characters — form field "Project ecosystem and users", maxlength read
     from https://nlnet.nl/propose/ on 2026-09-07. Checked by
     tools/dossier/field_length_gate.py; a browser truncates an over-long
     paste silently. -->

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
path is standard WebRTC, the coded lane runs over plain UDP, and the relay
speaks a protocol documented in the repository, reached through a single
hostname a deployer sets. The shipped defaults point at hosted third-party
endpoints - a relay on a commercial edge platform, public STUN servers, and two
vendors' DNS-over-HTTPS resolvers - and every one of them is replaceable by
editing that default: STUN and DoH are IETF standards with many public and
self-hostable servers, and anyone can run their own relay from the documented
protocol. Someone can adopt the transport without adopting the application, and
someone can run the server without asking anyone for permission - it is
AGPL-3.0, so running a modified one as a service means publishing the changes.
```

## Attachments and links

```
Repository          https://github.com/tlscodes/liveresilient
Problem statement   tools/dossier/PROBLEM_STATEMENT.md
Measurements        tools/dossier/manifest.tsv - path, size and hash per file
Known gaps          SECURITY.md
Continuous integration, all six jobs green, on GitHub-hosted runners:
  main            run 33685010369
  working branch  run 34108151719
(The earlier tag v0.1.0-ci-green is NOT cited: its leak-gate job logged
 "LEAK GATE: NOT RUN" and its own summary says that is not a pass.)
```

## Did you use generative AI in preparing this proposal?

<!-- FIELD LIMIT 8000 characters — form field "AI model and prompts", maxlength read
     from https://nlnet.nl/propose/ on 2026-09-07. Checked by
     tools/dossier/field_length_gate.py; a browser truncates an over-long
     paste silently. -->

```
Yes. This project was built and this proposal drafted with heavy use of an AI
coding assistant, and the repository makes that visible rather than hiding it:
the planning documents, session notes and review prompts are committed
alongside the code.

The attached provenance log covers both sessions in which this proposal's text
was written: the model recorded on each individual response, the timestamp of
each exchange, every prompt verbatim, and the unedited output. 3,968 messages
between 2026-08-10 and 2026-09-07. The models are read from the records rather
than from what was configured, because a single turn can be answered by a
fallback model with no trace in its text: claude-opus-5 on 1,843 responses,
claude-fable-5 on 252, and 9 generated by the tool itself. Seven credential
strings are replaced in place with numbered markers; nothing else was removed,
including mistakes, retries and stopped turns.

The design decisions, the measurements and the acceptance criteria are mine -
the log shows where the assistant proposed and where I decided. Every number in
this application traces to a committed artifact rather than to a model's
recollection; I checked that figure by figure, and where a figure could not be
traced it was cut rather than softened - including two engineering numbers that
had been carried forward in prose and turned out to exist in no results file.
The repository also carries a number-source lint for prose lines; it is a
working tool, not the proof of this text.
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
