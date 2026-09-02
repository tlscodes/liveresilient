# NLnet application — draft answers

One answer per form field, in the order NLnet asks them. Two fields are left
open because only the applicant can fill them: the amount and the milestone
breakdown. Everything else is written and each factual claim points at a file
in the public repository.

Check the open call on `nlnet.nl/funding.html` before submitting. Calls reopened
3 September 2026 with a deadline of 3 November 2026, 12:00 CEST, and the
programme names changed after NGI Zero closed — see `FUNDING_FACTS.md`.

---

## Project name

LiveResilient — messaging and calling that still works on a link that carries
packets but not a conversation.

*(One name, everywhere. The repository, the licence headers and this
application should not use three. Currently the repository is "LiveResilient",
the internal documents say "voice_call_kit" and the licence files say "Voice
Call Kit"; pick one before submitting and make the other two follow.)*

## Abstract — can you explain the whole project in a few sentences?

When a network is throttled rather than cut, people are left with a few
kilobits per second, heavy packet loss and seconds of latency. Ordinary
messengers fail there, not because the link is dead but because they assume a
working congestion-control loop and enough bandwidth to finish an upload.
LiveResilient is a calling and messaging kit built for that floor: bulk content
travels as rateless coded symbols over plain UDP, so loss costs proportional
extra symbols instead of a stalled round trip, and every feature has a wire
budget proven by a gate rather than a claim.

Six features — text, a news page, a photograph, a voice note, a short video
note and live push-to-talk — fit in 29 to 5,926 bytes and have been measured
end to end on a physical iPhone over a shaped link. A 4 MiB transfer that never
completed at all on a reliability-managed channel at 60% loss completed and
hash-verified in 303 seconds on the new lane. All of it is public, Apache-2.0
for the client and AGPL-3.0 for the server, with continuous integration green
on infrastructure that is not the developer's machine.

## Have you been involved with projects or organisations relevant to this project before?

This is a solo project by a software developer registered in the Netherlands as
Living Stone Apps. It has no institutional backers, no users and no letters of
support, and the application does not ask the reviewer to take any of those on
trust.

What exists instead is a public record of the engineering. The repository
contains the transport matrix as an append-only log including every failed run,
the codec gate logs, the device measurements, and a manifest recording the size
and hash of each artifact so a reviewer can confirm the file they are reading is
the file that was measured. Where a result is weaker than its label suggests —
the push-to-talk row is judged on liveness, not continuity — the document says
so before a reviewer has to find it.

## Requested amount

```
[owner] amount in euro
```

The successor programme announces 5,000 to 50,000 euro per proposal. Under
NGI Zero, anything above 50,000 required one or more successfully completed
smaller projects first; the equivalent rule for the current programme was not
published as of 2 September 2026. Ask for the amount the milestones below
actually cost and no more — cost effectiveness is 30% of the score, and an
inflated number is the easiest thing in an application to disbelieve.

## Explain what the requested budget will be used for

```
[owner] hours per milestone and the rate behind them
```

Four milestones, each with a mechanical acceptance test, in the order they
should be funded:

1. **End-to-end encryption on the datagram lane.** The lane that carries bulk
   content on lossy links has no encryption layer of its own today. `SECURITY.md`
   states this plainly. Nobody should be pointed at this tool until it closes.
   Acceptance: the six transport matrix rows re-run with the layer in place and
   the measured overhead recorded in the results file.
2. **An independent security audit, and the work to answer it.** The project
   has never been audited. Acceptance: the report published in the repository
   alongside the commits that answer each finding.
3. **Push-to-talk continuity.** The live voice lane survives the hardest
   profile but delivered 10 of 60 bundles with a 40.7-second gap on the
   recorded run. Acceptance: a stated continuity bar, met on a physical device,
   replacing today's liveness-only rule in the test.
4. **A supervised pilot.** Acceptance: the six end-to-end rows reproduced on
   testers' own devices rather than on the developer's, so that "it works for
   people" becomes a measurement.

Every milestone here follows the pattern the repository already uses: a
`verify_cmd` that exits zero, and no milestone reported complete without it.

## Compare your own project with existing or historical efforts

Delay-tolerant and mesh projects — Briar, Serval, and the DTN line of work —
solve the case where there is no infrastructure at all, using local radio or
store-and-forward between devices. This project addresses the different and
more common case: infrastructure exists and is reachable, but the link it gives
you is too poor for software that assumes a healthy one.

Against mainstream messengers the difference is measurable rather than
philosophical: the same transfer, the same shaped link, one that never
completes and one that completes and verifies. Against low-bitrate codec work
such as Codec2, this project is a consumer, not a competitor — the contribution
is the budget discipline and the transport around it, not the vocoder.

Rateless coding itself is decades old and no novelty is claimed for it. What is
new here is the combination held to a measured floor: coded transport, wire
budgets per feature, and the whole thing demonstrated on a real handset.

## What are significant technical challenges you expect to solve?

Encrypting the datagram lane without giving back the loss tolerance that
justifies it, since a handshake that needs a reliable round trip reintroduces
the failure the lane exists to avoid. Establishing a continuity bar for live
voice that is honest at 60% loss — high enough to mean something, low enough
to be reachable. Building the lane's parameters from measured link conditions
rather than constants calibrated on one network, a mistake this project has
already made once and fixed. And reproducing device results on hardware the
developer does not own, which is where most single-machine projects turn out to
have been measuring their own machine.

## Describe the ecosystem of the project, and how you will engage with stakeholders

Honest position first: there is no community around this yet. The repository
became public in September 2026 and has no external contributors.

The plan is to earn one rather than announce one. The first approach is to
digital-rights organisations that document shutdowns — Access Now's #KeepItOn
coalition and the measurement groups whose data this application cites — not
for endorsement, but to have the threat model and the pilot design reviewed by
people who talk to affected users. The audit milestone brings in a second set
of outside eyes with a published report. The transport lane and the codec
bindings are the parts most reusable by others, and they are packaged so they
can be taken without the application around them.

## Attachments

```
Repository        https://github.com/tlscodes/liveresilient
CI, green         tag v0.1.0-ci-green, run 33610621039
Problem statement tools/dossier/PROBLEM_STATEMENT.md
Measurements      tools/dossier/manifest.tsv — path, size and hash per artifact
Known gaps        SECURITY.md
```

## Generative AI disclosure

This project was built with heavy use of an AI coding assistant, and the
repository makes that visible: the planning documents, session notes and review
prompts are committed alongside the code. All design decisions, every
measurement and the acceptance criteria are the applicant's, and every number
in this application traces to a committed artifact rather than to a model's
recollection. The documents are stated in the language they were written in
rather than laundered, which seemed the more honest option when the form asks
the question directly.

---

## Every number in this draft, and where it comes from

Check each row before submitting. A figure that cannot be traced is cut, not
softened — that rule is why this project's documents survive being checked.
This section is for the applicant and does not go into the form.

```
29 to 5,926 bytes, six features      tools/phase5/h3_results.tsv
measured end to end on an iPhone     tools/dossier/e2e_ios_results.tsv
4 MiB never completed at 60% loss    tools/t2/h2_results.tsv rows 266-267
same object, 303 s, hash-verified    tools/t2/h2_results.tsv rows 268-269
10 of 60 bundles, 40.7 s gap         tools/dossier/e2e_ios_results.tsv, ptt
CI green, tag v0.1.0-ci-green        GitHub Actions run 33610621039
5,000-50,000 EUR per proposal        nlnet.nl, successor programme page
above 50,000 needs a completed one   nlnet.nl, NGI Zero applicant guide
150k per proposal, 500k lifetime     nlnet.nl, NGI Zero applicant guide
scoring 30 / 40 / 30, floor 5.0/7    nlnet.nl, applicant guide
calls reopened 3 Sept, due 3 Nov     nlnet.nl/funding.html
repository public since Sept 2026    git log, first public push
```

No acceptance probability appears anywhere in this application, because none is
published. See `FUNDING_FACTS.md`.
