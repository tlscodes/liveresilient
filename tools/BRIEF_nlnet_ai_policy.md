# Brief — how to answer this form honestly, given the AI policy

Paste the block below into a terminal session on Fable 5.1. It asks the model to
verify everything itself rather than trusting a summary, because the answer
decides whether an application is accepted at all.

---

```
Research this yourself from the primary pages. Do not take any of the figures
below on trust — I read them today and I may have read them wrong, and the
consequence of a wrong reading here is a rejected application.

Pages to read:
  https://nlnet.nl/propose/
  https://nlnet.nl/foundation/policies/generativeAI/
  https://nlnet.nl/restack/           and its guide for applicants
  https://nlnet.nl/funding.html

THE SITUATION
A solo developer in the Netherlands, an eenmanszaak, is applying to NLnet's
Restack Fund by the 3 November 2026 deadline for an open-source calling and
messaging kit built for links that carry packets but not a conversation. The
repository is public, Apache-2.0 for the client and AGPL-3.0 for the server,
with CI green and measured results committed.

The application was drafted with heavy AI assistance, and the whole project was
built that way. The drafts are in tools/dossier/ — NLNET_SUBMISSION_READY.md is
one answer per form field, APPLICATION_NLNET.md is the longer version, and
FUNDING_FACTS.md records what each programme publishes.

WHAT I BELIEVE I READ — check every line of this
- The form says: "We are not interested in AI-generated projects or proposals."
- The policy says applicants MAY use these tools if the use is disclosed, and
  requires a prompt provenance log: the model and version, dates and times, the
  prompts themselves, and the unedited output.
- The policy says grantees must not present generated content as their own
  human-authored work, and that failure to comply may mean rejection or
  termination of a running grant.
- The form has a field of up to 8000 characters for pasting those prompts and
  outputs, or a file upload.
- The form says "answer in plain text and in English, in your own words".
- Character limits: summary 1000, budget 4000, comparison 4000, technical
  challenges 4000, ecosystem 2000, experience 2000, other funding 1000.

QUESTIONS, ranked. The first is the one that matters.

1. Where exactly is the line between "AI-generated proposal", which they refuse,
   and "AI-assisted, disclosed", which they permit? Quote the text that draws
   it. Then say plainly what this applicant should do: rewrite every answer
   themselves using the drafts as source material, submit the drafts as-is with
   a full log, or something else. I want the honest reading, not the
   comfortable one — if the honest reading is that these drafts cannot be
   submitted as they stand, say so.

2. The applicant's first language is Persian, not English. Does "in your own
   words" mean something different for someone using a tool to express their
   own engineering in a second language than for someone having a tool invent a
   proposal? Is there anything in the policy or the surrounding pages that
   speaks to this, or is it silent? Do not invent a charitable reading that the
   text does not support.

3. The provenance log. This project's assistance ran across many sessions over
   months, not a handful of prompts, and the transcripts are large. What does a
   log that actually satisfies the policy look like at that scale — everything,
   a representative sample, or a summary of how the tool was used? What would
   you submit, and what is the risk of each choice? If the policy does not
   answer this, say it does not and recommend asking them directly at the
   office hour on 30 September.

4. Two answers exceed their limits: the summary by 649 characters and the budget
   by 1693. The form also says to be short and to the point. Which parts of an
   over-long answer are the ones a reviewer actually needs, on a form scored
   30% technical, 40% relevance and impact, 30% cost effectiveness? Do not
   rewrite them for me — say what to cut and why, so the applicant can cut it
   themselves in their own words.

5. Restack specifically. Read its own guide rather than the closed NGI Zero
   one. What does it require that the general form does not, is the 5,000 to
   50,000 range still current, and is there anything in its scope this project
   should lead with or avoid claiming?

6. Anything else on those pages that would sink this application and that I have
   not asked about.

Answer with quotes and their source URLs. Where the pages are silent, say so
rather than filling the gap. Advice only — do not edit any files.
```

---

## Why I am asking rather than answering

I read these pages and formed a view: that the policy permits disclosed
assistance and refuses passed-off authorship, and that the right move is for the
applicant to rewrite each answer in their own words with the drafts as source
material, plus a log.

That view may be right and it is still one reading of a policy whose penalty for
being wrong is the whole application. A second reading, from the primary sources,
costs one dispatch. The question of what "in your own words" means for a
non-native speaker is the part I am least certain about, and it is the part that
decides how much rewriting is honest rather than cosmetic.
