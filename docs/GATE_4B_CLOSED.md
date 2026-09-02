# The last gate, and why its evidence is shaped the way it is

2026-08-18. Gate 4b was the fortieth and final acceptance item. This is what
closed it, what the evidence actually supports, and what it deliberately does
not claim.

## What was missing was a privilege, not code

Attaching a recorder to the attached device needs root. An unattended run cannot
answer a password prompt, so the script had been written and committed with its
grant line in its own header, and nothing else could happen until the maintainer
typed one line:

```
sudo visudo -f /etc/sudoers.d/t2rig-extra
behnam ALL=(root) NOPASSWD: $REPO/tools/t2/step7_trace.sh
```

The exact absolute path, never `ALL`, and no `SETENV:` because this script needs
no environment. Every call site uses `sudo -n`, so a missing rule fails loudly
and immediately rather than hanging a night run behind a prompt nobody is awake
to answer.

The cost of that grant is stated plainly in the script's header and repeated
here: the script is writable by the ordinary user, so anything running as that
user can obtain root through it. On a single-user development machine that is an
accepted trade. The stricter form is a root-owned copy with the rule pointing at
the copy.

## Getting the connection inside the recording window

The first three attempts recorded nothing relevant, and the reason is worth
keeping. A cold run of the on-device test spends about four minutes compiling
and another four installing; the connection happens at the very end. Windows of
300 and 200 seconds all closed before it. The fourth attempt opened a 900-second
window and started the run inside it, and the exchange landed with room to
spare.

Nothing about this was subtle. It is recorded because the failure mode — a
capture that is technically valid and contains none of what it was opened for —
passes a naive check for the label that must be absent. Which is exactly the
next section.

## The two findings are not the same kind of claim

The original predicate was one line and looked symmetric:

```
! strings capture | grep -qiF "$(cat real_name)" \
&&  strings capture | grep -qiF "$(cat public_name)"
```

It is not symmetric, because the two halves have opposite logical shapes.

```
"the public name appears"    EXISTENTIAL   one witness settles it
                                           — but only a LOCATED one
"the real name does not"     UNIVERSAL     only as strong as the
                                           COVERAGE behind the scan
```

Three concrete problems followed from treating them alike:

1. **A recording of nothing passes the absence half.** So does a recording of
   the wrong interface, or one that stopped before the connection. Absence is
   only meaningful alongside a positive that proves the exchange was captured.
2. **`strings | grep` proves nothing about where.** The recorder writes its own
   metadata into the file — interface names, comments, host names. A hit there
   is not something the device sent.
3. **The full recording cannot be committed.** It is 65 MB and holds fifteen
   minutes of everything the attached device sent, most of it unrelated personal
   traffic. Filtering it down to the exchange under test destroys the absence
   claim: absent from an excerpt you chose yourself is nearly no evidence.

A fourth problem surfaced while fixing these: the recorder wrote a file it
cannot itself fully re-read — `block ... has a length of 262146 that is not a
multiple of 4` — so a parser reaches a fraction of the bytes while a byte scan
reaches all of them.

## What the checker does instead

`tools/step7_analyze.py` decides each half in the form its logic requires.

```
UNIVERSAL half   a streaming byte scan over EVERY byte of the full recording,
                 in three encodings (ASCII/UTF-8, UTF-16LE, UTF-16BE), with
                 read buffers overlapped so a match cannot hide in a seam —
                 and a scanner SELF-TEST that plants each encoding, including
                 across that seam, and requires the scanner to find them all
                 before its verdict counts. Coverage measured, not asserted.

EXISTENTIAL half the witness must be LOCATED: the offset has to fall inside a
                 captured packet's data region, and the surrounding bytes are
                 parsed far enough to name the field the value sits in.
```

What it found, on the recording of 2026-08-18:

```
scanned                68,511,532 bytes, three encodings, scanner self-tested
real name              found nowhere
public name            packet 4, offset 191, inside that packet's data region
the field              the server_name offered in the clear in a handshake record
offered extensions     0, 65037, 23, 65281, 10, 11, 35, 13, 51 — nine, and the
                       extension under test among them
```

That last row matters more than it looks. It rules out the reading where the
exchange simply never offered the capability and the name was absent for the
dullest possible reason.

## What is committed, and how it stays auditable

The 65 MB recording is **not** committed — size, and privacy. Committed instead:

```
docs/evidence/step7_trace.pcap             the 6 KB excerpt holding the witness
docs/evidence/step7_trace_provenance.txt   tool, dates, host, device, interface
docs/evidence/step7_trace_analysis.txt     the full file's sha256, size, scan
                                           coverage, encodings, and the located
                                           witness with its field
```

So the claim becomes: *absence was verified against the file with this hash, by
this scan, on this date; the committed excerpt is a hash-linked piece of that
file containing the located witness.* Internally consistent without the
original, and re-executable against any hash-matching copy.

`--recheck` is the mode that makes this honest rather than merely convenient. It
**re-measures the existential half live** from the committed excerpt — never
reads that result back from the report — and **validates the universal half from
the record**, then says which was which in its first line:

```
recheck: existential claim (present-label witness) MEASURED now; universal claim
(absent-label scan) VALIDATED from the recorded report only — its input, the
full capture, is not present to re-measure
```

If the full recording is present and its hash matches, the same command
re-measures both and says it was upgraded. Verified both ways on this machine.

## What holds it to its words

`packages/adaptive_transport/test/ticket4b_trace_evidence_test.dart`, seven
tests. Six positive, all routed through one predicate function, and one negative
control that attacks that same function with five mutations of the record: a
flipped absence result, coverage short of the file it names, an unlocated
witness, a missing scanner self-test, and a witness naming a different label.
Each must be rejected. A control on a different code path would prove nothing.

## What this does not claim

One recorded exchange is one exchange. It does not prove the protection holds on
another network, against another peer, or today. It does not claim anything
about occurrences that are encrypted — "not in the clear" is the entire claim. A
label split across two segments would evade a byte scan; the excerpt shows this
exchange arrived in one record, which is why that gap is small here and not
zero.

And one process note, recorded because the alternative is quiet substitution:
the analysis tool's two-mode split was authored by Fable 5 under a written
brief, but the Dart test above was **not** — three narrowed briefs were stopped
by the content review, so it was authored on the session model. The stops came
from the files the agent had to read, not from the brief's length.
