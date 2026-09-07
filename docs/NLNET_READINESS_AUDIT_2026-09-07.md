# NLnet submission readiness — audit of 2026-09-07

Five independent lenses over the dossier (staleness, number provenance, owner blockers, fit
against the live form, and the honesty chapters), each finding then put to an adversarial
verifier that had to confirm it from the files before it survived. 55 agents, ~1010 tool calls.
Every entry below carries the anchor it was found at.

**Verdict: do not submit today.** Two prepared blocks exceed the form's field limits and would
be silently truncated on paste, a mandatory attachment does not exist, and one paragraph asserts
something the shipped defaults contradict. None of these is deep work; the set below is a
sitting.

---

## The document set

| # | Path | For | State |
|---|------|-----|-------|
| 1 | `tools/dossier/NLNET_SUBMISSION_READY.md` | the only file pasted into the form, one block per field | text frozen 2 Sep; two blocks over the form's limits; no block for the form's first required field |
| 2 | `tools/dossier/APPLICATION_NLNET.md` | fallback for fields the ready file does not cover | stale: a 500 EUR line against 1,700 elsewhere, "the four amounts" in a six-milestone budget, 20 lint violations |
| 3 | `tools/dossier/FUNDING_FACTS.md` | the external fact base | two stale rows (deadline time zone, successor scale-up) |
| 4 | `tools/dossier/manifest.tsv` | the hash gate the application cites as its evidence | current — 139 rows, 0 mismatched, re-verified at `927502f` |
| 5 | `tools/dossier/LANE_TABLE.md` | reviewer-facing record of which lanes are wired, cited twice | stale against this branch; its own self-check grep now returns the opposite of what it claims |
| 6 | `SECURITY.md`, `README.md` | attachments a reviewer opens to check the disclosure | each carries one false line |
| 7 | `tools/dossier/private/APPLICANT.md` | the owner's private field sheet, correctly untracked | stale budget section |

`APPLICATION_DDP.md`, `CHART_AUDIT.md`, `PROPOSAL_SKELETON.md`, `TECH_DOSSIER.md`,
`EXEC_SUMMARY.md` and `PROBLEM_STATEMENT.md` are not part of this submission. Do not paste from
them.

## Blockers

1. **The abstract is 1,652 characters into a 1,000-character field.**
   `NLNET_SUBMISSION_READY.md:35-60`. The browser keeps the first 1,000 and drops the rest with
   no warning; the cut lands at "…characterises the transport", discarding the 4 MiB / 60 % loss
   / 303 s result, the licence line and the CI line — the three strongest sentences in it. Cut to
   1,000 with the measured result kept, and write the measured length beside the heading so the
   next edit cannot reintroduce it.

2. **The budget answer is 5,694 characters into a 4,000-character field.**
   `NLNET_SUBMISSION_READY.md:91-180`. The cut falls mid-word inside M4, and the M5 and M6
   justifications vanish while the summary table still asks for 38,700.

3. **"Yes" to generative AI, with no provenance log.** `NLNET_SUBMISSION_READY.md:278-294`. The
   policy requires the model, the dates and times, the prompts and the unedited output; none of
   the four exists as an artifact. Non-compliance may result in rejection. The material for it is
   in the repository already (`docs/FABLE_SESSION_PROMPT.md`, `docs/PROMPT_plan_review.md`,
   `docs/DREAM_ROADMAP_PROMPTS.md`), scoped to the drafting sessions.

4. **An interoperability absolute the app's own defaults falsify.**
   `NLNET_SUBMISSION_READY.md:59` and `:261` say no proprietary service is anywhere in the path
   and no component depends on a platform a single vendor controls. Against:
   `apps/reference_app/lib/src/call_session.dart:138` (a Cloudflare Workers relay as the default,
   registered on every call at `:541`), `tools/cloudflare_relay_worker/wrangler.toml` (Durable
   Objects, with no portable implementation here),
   `apps/reference_app/lib/src/startup_manifest.dart:168` (Google STUN), and
   `packages/adaptive_transport/lib/src/resilient/txt_query_transport.dart:238-239` (Cloudflare
   and Google DoH). The same grep falsifies `SECURITY.md:68`. The true and still strong claim:
   the media path is standard WebRTC and the coded lane plain UDP, the relay is replaceable by
   hostname with its protocol documented, and the shipped default deployment runs on Cloudflare
   Workers.

5. **A claimed lint that does not check the submitted file.**
   `NLNET_SUBMISSION_READY.md:288-290` says a lint enforces the no-unsourced-number rule on the
   documents this text came from. `number_source_lint.py` reports 0 violations on that file only
   because every numeric line sits inside a fence, which the lint skips by design
   (`number_source_lint.py:14-16`); the same lint on `APPLICATION_NLNET.md` reports 20. Narrow
   the sentence to what the lint actually checks, or clear the 20 first.

## Should-fix

- `LANE_TABLE.md:41` instructs the reader to run a grep that "returns nothing"; it now returns
  `apps/reference_app/lib/main.dart:321`. Rows 72-73 call photo and video note unwired though
  `call_session.dart:642-648` opens both. `README.md:38` repeats it. This one understates the
  project on the axis the programme scores highest.
- `APPLICATION_NLNET.md:152` — "about 500 EUR" against 1,700 at `:65`, `:87`, `:313`; four
  handsets at 300 each already exceed 500. Caused by an un-merged duplicate paragraph at
  `:157-159` / `:164-172`.
- `APPLICATION_NLNET.md:146`, `:200-201` — "the four amounts sum exactly to the requested total"
  in a six-milestone budget.
- `APPLICATION_NLNET.md:119-127` — M2 justifies its 5,000 EUR by a "50 kEUR line" that exists
  nowhere, while `FUNDING_FACTS.md:43-45` and `:310` of the same application both say the audit
  is in kind and must not be invoiced.
- `SECURITY.md:52-56` discloses only the two Android `.so` files; the committed
  `PtTransport.xcframework` is disclosed nowhere, and M5 cites SECURITY.md for both.
- The CI evidence anchor at `NLNET_SUBMISSION_READY.md:275` points at a tag whose leak-gate job
  logged "NOT RUN" and whose own summary says it is not a pass. Cite a genuinely green run.
- `packages/media_webrtc_flutter/LICENSE` on `origin/main` reads "TODO: Add your license here."
  against the Apache-2.0 claim.
- The 4 MiB contrast at `:51-53` credits "the coded lane", but the replay corpus shows
  `lane: fountain` on both the failing and the passing run and `transport: datagram` only on the
  passing one — as cited, it reads backwards.

## Owner decisions

- **Which fund.** The form's first required field is a select, and nothing in the document set
  names one; only `tools/BRIEF_nlnet_ai_policy.md:22-24` mentions Restack, whose scope excludes
  AI-related projects. The choice decides which scope every answer is read against.
- **Repository publication — done.** `github.com/tlscodes/liveresilient` is public, root
  Apache-2.0, `server/LICENSE` AGPL-3.0, CI on GitHub-hosted runners. *(Verified directly this
  session.)* Open: `origin/main` is 50 commits behind this branch. Merging before submission
  falsifies `LANE_TABLE.md` unless it is regenerated in the same commit; not merging means a
  reviewer sees the 2 September code.
- **Demo video.** None, and the submission promises none — optional, not a prerequisite.
- **Legal and financial route.** Resolved in the private sheet: eenmanszaak, paid directly, no
  fiscal host. That file's own budget section is stale against the submitted one.
- **The euro amounts.** 38,700 = 740 h × 50 + 1,700 is owner planning, not measurement, and the
  application says so at `APPLICATION_NLNET.md:313`. The 65 EUR/h ceiling is addressed to the
  reviewer as their own published convention and could not be found on any current NLnet page —
  confirm it or drop the attribution.
- **Whether AI-drafted blocks may be pasted as-is**, given the form's "answer in your own words".

## What changed since the text was frozen

Strengthens the application and is currently unmentioned: chat, photo, voice note and video note
now ride the live call (`dbd357f`); the app itself was measured across all seven impairment
profiles with real decoded media, 42 rows, 0 FAIL (`3a5d6b1`); three further
constant-calibrated-on-one-network defects were found and fixed with a lesson each; the
retransmit-timer fix moved carried utilization from 15-43 % to 86-88 % and duplicate bytes from
81 % to 2.1 %; the TXT/DNS query lane now runs inside the app with its own suite (`6e8c95c`); and
a signed store-and-forward queue crosses a multi-minute total cut.

That last one contradicts the framing: `NLNET_SUBMISSION_READY.md:35` says "throttled rather
than cut", and `:198` disclaims store-and-forward — while the newest measured capability is
exactly a queue that survives a total cut.
