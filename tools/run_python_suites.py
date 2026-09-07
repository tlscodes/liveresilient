#!/usr/bin/env python3
"""Run every Python suite under tools/, so none of them can sit outside the gate.

The Dart side already learned this: the CI test glob was widened after a loopback
soak sat red while CI reported green, because the glob never reached its directory.
The same hole existed in the other language — sixteen `test_*.py` files under
tools/, of which CI named exactly two. Measured 2026-09-07: fifteen of the sixteen
passed locally and no gate had ever run twelve of them.

Discovery, not a list, so a suite added tomorrow is covered without editing this
file. Each suite runs from its own directory, because they import their siblings by
plain module name.

A suite that cannot run here is EXCLUDED BY NAME with its reason, printed on every
run, and the exclusion list is itself checked: naming a file that no longer exists
fails the gate rather than quietly shrinking coverage.

Usage:
    python3 tools/run_python_suites.py            # run everything discoverable
    python3 tools/run_python_suites.py --list     # print what would run, run nothing

Exit 0 only when every discovered suite exited 0.
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

TOOLS = Path(__file__).resolve().parent
REPO = TOOLS.parent

# path relative to the repository root -> why it cannot run in CI
EXCLUDED: dict[str, str] = {
    "tools/test_hamseda_v4.py": (
        "runs its twelve checks against the operator's own capture at a path outside "
        "the repository (see the usage line in its docstring); CI has no way to supply "
        "that input, and committing one would put a personal recording in the repo"
    ),
}


def discover() -> list[Path]:
    return sorted(p for p in TOOLS.rglob("test_*.py") if p.is_file())


def main(argv: list[str]) -> int:
    listing_only = "--list" in argv
    found = discover()
    if not found:
        print("::error::no test_*.py found under tools/ — that is itself a gate failure")
        return 1

    stale = [name for name in EXCLUDED if not (REPO / name).is_file()]
    for name in stale:
        print(f"::error::{name} is excluded but no longer exists — remove the stale entry")

    running: list[Path] = []
    for path in found:
        rel = path.relative_to(REPO).as_posix()
        if rel in EXCLUDED:
            print(f"skipped   {rel}\n          {EXCLUDED[rel]}")
        else:
            running.append(path)

    print(f"discovered {len(found)} suite(s); running {len(running)}, skipping {len(found) - len(running)}")
    if listing_only:
        for path in running:
            print(f"  would run {path.relative_to(REPO).as_posix()}")
        return 1 if stale else 0

    failed: list[str] = []
    for path in running:
        rel = path.relative_to(REPO).as_posix()
        proc = subprocess.run(
            [sys.executable, path.name],
            cwd=path.parent,
            capture_output=True,
            text=True,
        )
        if proc.returncode == 0:
            print(f"PASS      {rel}")
            continue
        failed.append(rel)
        # The whole output, never a tail: a failure whose evidence was truncated
        # has to be reproduced before it can be read, and this repository has a
        # gate about exactly that.
        print(f"FAIL      {rel}  (exit {proc.returncode})")
        if proc.stdout:
            print(proc.stdout)
        if proc.stderr:
            print(proc.stderr)

    print(f"\npython suites: {len(running) - len(failed)} passed, {len(failed)} failed")
    for rel in failed:
        print(f"::error::{rel} failed")
    return 1 if (failed or stale) else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
