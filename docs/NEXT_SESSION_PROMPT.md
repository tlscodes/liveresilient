Continue in $REPO, branch plan-v4-waves-1-to-6.

Six pieces, in this order, each verified before the next. Do not ask me
anything; where a choice is reversible, make it and record it in one line.

DO NOT open docs/TICKET4_API_SURFACE.md, and do not read section 4-bis of
docs/TICKET4_DECISION.md. Those are being handled in the other session.

1. docs/TICKET4_PIN_RECORD.md — the pin record your policy calls for: the
   pinned commit, the date it was pinned, the owner role, the next review
   date, and a bump log with one row per bump (date, from, to, which gates
   ran, outcome). Empty log with the column headers is correct today.

2. .github/workflows/ — the weekly monitor as a scheduled job. It lists new
   upstream commits on the linked paths since the pin, flags security
   keywords, and opens an issue. If it finds nothing it must still record
   that it ran; a monitor that is silent when healthy is indistinguishable
   from a monitor that is broken.

3. The six verify gates from your policy, wired as required checks on a bump
   pull request. Each gate is a command whose exit 0 proves it. A gate you
   cannot express as a command is not a gate — say so instead of writing a
   prose one.

4. The 180-day pin-age ceiling as a check that FAILS the build, not a
   warning. It reads the pin date from the record file in step 1.

5. Gate-name labelling. Roughly 20 of the plan's ~41 gates have no test
   whose name carries the gate id, so the ledger cannot be recomputed from
   the repository. Go through the test files and put the gate id at the
   front of the test name, e.g. test('3b  a STUN-only manifest under strict
   is an explicit failure', ...). Change ONLY test names — no assertions, no
   logic. Then verify the table builds itself:
       grep -rhoE "test\('[0-9][a-z]" --include='*_test.dart' . | sort -u
   Report which gate ids still have no test at all; those are real gaps, not
   labelling gaps, and must not be papered over with a renamed test.

6. Gate 1f — the one gate in the plan that was never built. The plan
   describes a mid-call re-evaluation loop with hysteresis: when measured
   conditions change during a call the configuration is re-derived, but the
   rate may move freely while the packetization time needs a larger
   hysteresis band, because changing it mid-call means renegotiating the
   session description. Read the ticket-1 section of
   docs/PLAN_five_tickets_v4.md for the anchors, implement it, and name the
   tests 1f. If this piece is stopped by the review pass, skip it, say so,
   and finish with steps 1-5 recorded.

For every piece: back the file up under .backups/ first, verify with the
package's own analyze and test, and write a dated row in the build ledger
inside docs/PLAN_five_tickets_v4.md with the command output from the same
turn. No row without its verifier output.
