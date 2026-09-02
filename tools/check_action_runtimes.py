#!/usr/bin/env python3
"""Report the Node runtime each pinned GitHub action actually declares.

A version tag does not tell you the runtime. actions/upload-artifact tagged v5
at a commit whose action.yml says node20, and a bump to "v5" left the
deprecation warning exactly where it was. The only reliable predicate is
`runs.using` inside the pinned commit itself, which is what this reads.

Usage:  python3 tools/check_action_runtimes.py
Exit 1 if any pinned action declares a deprecated runtime.
"""
import base64
import pathlib
import re
import subprocess
import sys

DEPRECATED = {"node12", "node16", "node20"}

wf = pathlib.Path(__file__).resolve().parent.parent / ".github" / "workflows"
pins = set()
for f in sorted(wf.glob("*.yml")):
    for m in re.finditer(r"uses:\s*([\w.-]+/[\w.-]+)@([0-9a-f]{40})", f.read_text(encoding="utf-8")):
        pins.add(m.groups())

bad = 0
for repo, sha in sorted(pins):
    using = "(no manifest)"
    for name in ("action.yml", "action.yaml"):
        r = subprocess.run(
            ["gh", "api", f"repos/{repo}/contents/{name}?ref={sha}", "--jq", ".content"],
            capture_output=True, text=True,
        )
        if r.returncode == 0 and r.stdout.strip():
            body = base64.b64decode(r.stdout).decode("utf-8", "replace")
            m = re.search(r"^\s*using:\s*[\'\"]?([\w.]+)", body, re.M)
            using = m.group(1) if m else "?"
            break
    flag = ""
    if using in DEPRECATED:
        flag = "  DEPRECATED"
        bad += 1
    print(f"{repo:34s} {sha[:8]}  {using}{flag}")

print(f"\n{len(pins)} pinned actions, {bad} on a deprecated runtime")
sys.exit(1 if bad else 0)
