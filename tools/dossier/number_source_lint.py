#!/usr/bin/env python3
"""Every-number-has-a-source lint for the dossier documents (gate T5).

Rule (mechanical, FULL_TEST_PLAN track 5): outside fenced code blocks, any
line containing a multi-digit number (2+ digits, the measurement shape) must
name its source on the same line with a `src:` tag, e.g.
    ... 5220B over 60s ... ‹src:tools/phase5/h3_results.tsv›
Single digits pass (section numbering, list markers). Fenced blocks pass
(they ARE quoted evidence, and quoting a TSV verbatim carries its own path).
Exit 0 = zero violations; violations are printed file:line: text.
"""
import re
import sys

NUM = re.compile(r"\d{2,}")
violations = 0
for path in sys.argv[1:]:
    in_fence = False
    with open(path, encoding="utf-8") as f:
        for i, line in enumerate(f, 1):
            if line.lstrip().startswith("```"):
                in_fence = not in_fence
                continue
            if in_fence:
                continue
            if NUM.search(line) and "src:" not in line:
                print(f"{path}:{i}: number without src: {line.rstrip()}")
                violations += 1
print(f"number-source lint: {violations} violation(s)")
sys.exit(1 if violations else 0)
