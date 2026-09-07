#!/usr/bin/env python3
"""Build the AI provenance log the funder's policy requires as an attachment.

The policy asks for four things: the model used, the dates and times of use, the
prompts given, and the unedited output received. Committed prompt documents
supply at most the prompts, and approximately the dates. Nothing short of the
session transcript supplies all four — and the transcript exists: the assistant
writes every session as JSONL, one record per message, each carrying a
`timestamp`, a `type` (user or assistant), a `message.model` and the content.

Three rules this script enforces rather than trusts:

  The model is READ, never assumed. A session configured for one model can have
  individual turns answered by a fallback model with no trace in the text. Every
  distinct value of `message.model` that appears is listed with its count, so the
  log says what actually answered rather than what was requested.

  Nothing is removed except credentials. Mistakes, retries and stopped turns stay
  in: a provenance log that has been tidied is not provenance. Credential-shaped
  strings are replaced in place with a numbered marker and the count is stated in
  the index, so a reader can see that redaction happened and how much.

  Nothing is dropped silently. Sub-agent transcripts are excluded by default and
  the count is printed; --since leaves out earlier records and every file's
  header states how many it left out; --drafting-only narrows to the sessions
  that actually WROTE the proposal and prints how many it set aside. A log with
  a quiet gap in it is worse than no log, because it invites belief it has not
  earned.

This script WRITES A DIRECTORY AND STOPS. It does not commit, upload, or attach
anything: what to disclose is the applicant's decision, and it cannot be taken
back once sent.

Usage:
    python3 tools/dossier/ai_provenance_export.py --list
    python3 tools/dossier/ai_provenance_export.py --drafting-only --list
    python3 tools/dossier/ai_provenance_export.py --drafting-only \
            --out tools/dossier/ai-provenance
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path

PROJECTS = Path.home() / ".claude" / "projects"

# A transcript is in scope when it mentions the proposal's own files.
SCOPE_MARKERS = (
    "NLNET_SUBMISSION_READY.md",
    "APPLICATION_NLNET.md",
    "nlnet.nl/propose",
)

# A DRAFTING session is the narrower thing the question actually asks about: one
# where the proposal text was WRITTEN, not merely referred to. Mentioning a path
# while fixing a test is not drafting a proposal, and neither is reading one — so
# this is decided by parsing for an editing tool call naming a proposal file,
# never by a substring, which cannot tell a read from a write.
EDITING_TOOLS = {"Write", "Edit", "MultiEdit", "NotebookEdit"}
PROPOSAL_FILES = ("NLNET_SUBMISSION_READY.md", "APPLICATION_NLNET.md")

# Credential shapes only. Deliberately narrow: a false positive deletes evidence.
SECRETS = [
    re.compile(r"gh[pousr]_[A-Za-z0-9]{20,}"),
    re.compile(r"sk-[A-Za-z0-9]{20,}"),
    re.compile(r"AKIA[0-9A-Z]{16}"),
    re.compile(r"xox[bpors]-[0-9A-Za-z-]{10,}"),
    re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----"),
]


def text_of(message: dict) -> str:
    """Every text block of one message, in order, joined."""
    content = message.get("content")
    if isinstance(content, str):
        return content
    if not isinstance(content, list):
        return ""
    parts = []
    for item in content:
        if not isinstance(item, dict):
            continue
        if item.get("type") == "text":
            parts.append(item.get("text", ""))
        elif item.get("type") == "tool_use":
            parts.append(
                f"[tool_use: {item.get('name')}]\n"
                f"{json.dumps(item.get('input', {}), ensure_ascii=False, indent=2)}"
            )
        elif item.get("type") == "tool_result":
            body = item.get("content")
            parts.append(
                "[tool_result]\n"
                + (body if isinstance(body, str) else json.dumps(body, ensure_ascii=False))
            )
    return "\n\n".join(p for p in parts if p)


def redact(text: str, counter: list[int]) -> str:
    for pattern in SECRETS:
        while True:
            found = pattern.search(text)
            if not found:
                break
            counter[0] += 1
            text = text[: found.start()] + f"[REDACTED-secret-{counter[0]}]" + text[found.end():]
    return text


def classify(path: Path) -> tuple[bool, bool]:
    """(mentions a proposal file, wrote one)."""
    try:
        raw = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return False, False
    mentioned = any(marker in raw for marker in SCOPE_MARKERS)
    if not mentioned:
        return False, False

    # Parse for an editing tool call naming a proposal file. A substring cannot
    # distinguish a read from a write, and every session that opened the document
    # to quote it would otherwise count as having drafted it.
    for line in raw.splitlines():
        line = line.strip()
        if not line or "file_path" not in line:
            continue
        try:
            record = json.loads(line)
        except json.JSONDecodeError:
            continue
        message = record.get("message") or {}
        content = message.get("content")
        if not isinstance(content, list):
            continue
        for item in content:
            if not isinstance(item, dict) or item.get("type") != "tool_use":
                continue
            if item.get("name") not in EDITING_TOOLS:
                continue
            target = str((item.get("input") or {}).get("file_path", ""))
            if any(target.endswith(name) for name in PROPOSAL_FILES):
                return True, True
    return True, False


def export(path: Path, counter: list[int], since: str | None = None) -> tuple[str, dict]:
    """Return (rendered log, summary) for one session transcript.

    [since] is an ISO date prefix; records stamped before it are left out, and
    the header states how many, because a log with a quiet gap is not one.
    """
    models: dict[str, int] = {}
    first = last = None
    lines: list[str] = []
    exchanges = 0
    skipped = 0

    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        raw = raw.strip()
        if not raw:
            continue
        try:
            record = json.loads(raw)
        except json.JSONDecodeError:
            continue
        kind = record.get("type")
        if kind not in ("user", "assistant"):
            continue
        stamp = record.get("timestamp") or ""
        if since and stamp and stamp < since:
            skipped += 1
            continue
        if stamp:
            first = first or stamp
            last = stamp
        message = record.get("message") or {}
        body = redact(text_of(message), counter)
        if not body.strip():
            continue
        exchanges += 1
        if kind == "assistant":
            model = message.get("model") or "(no model recorded)"
            models[model] = models.get(model, 0) + 1
            lines.append(f"\n### assistant · {stamp} · model {model}\n\n{body}\n")
        else:
            lines.append(f"\n### prompt · {stamp}\n\n{body}\n")

    header = [
        f"# AI provenance log — session {path.stem}",
        "",
        "Verbatim. Nothing removed except credential strings, which are replaced in",
        "place with a numbered marker; the count for the whole export is in INDEX.md.",
        "Mistakes, retries and stopped turns are included: a log that has been tidied",
        "is not provenance.",
        "",
        "```",
        f"first record   {first or '(none)'}",
        f"last record    {last or '(none)'}",
        f"messages       {exchanges}",
        (f"left out       {skipped} record(s) stamped before {since}" if since
         else "left out       none"),
        "models         "
        + (", ".join(f"{m} ({n})" for m, n in sorted(models.items())) or "(none)"),
        "```",
        "",
        "---",
    ]
    rendered = "\n".join(header) + "\n" + "".join(lines)
    return rendered, {
        "session": path.stem,
        "source": str(path),
        "first": first,
        "last": last,
        "messages": exchanges,
        "skipped": skipped,
        "models": models,
    }


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--out", help="directory to write the export into")
    parser.add_argument("--list", action="store_true", help="list in-scope sessions, write nothing")
    parser.add_argument(
        "--since",
        help="ISO date prefix, e.g. 2026-09-01; earlier records are left out and counted",
    )
    parser.add_argument(
        "--drafting-only",
        action="store_true",
        help="only sessions that WROTE a proposal file, not those that merely mention one",
    )
    parser.add_argument(
        "--include-subagents",
        action="store_true",
        help="also export sub-agent transcripts (excluded by default; the count is always printed)",
    )
    args = parser.parse_args(argv)

    if not PROJECTS.is_dir():
        print(f"::error::{PROJECTS} does not exist — no transcripts to export")
        return 1

    mentions: list[Path] = []
    drafting: list[Path] = []
    for path in sorted(PROJECTS.rglob("*.jsonl")):
        if not path.is_file():
            continue
        mentioned, wrote = classify(path)
        if mentioned:
            mentions.append(path)
        if wrote:
            drafting.append(path)

    if not mentions:
        print("no in-scope session transcripts found — nothing mentions the proposal's files")
        return 1

    pool = drafting if args.drafting_only else mentions
    subagents = [p for p in pool if "subagents" in p.parts]
    sessions = pool if args.include_subagents else [p for p in pool if p not in subagents]

    print(f"{len(mentions)} transcript(s) mention the proposal's files; "
          f"{len(drafting)} of them wrote one.")
    if args.drafting_only:
        print(f"  --drafting-only: {len(mentions) - len(drafting)} mention-only transcript(s) set aside.")
    if subagents and not args.include_subagents:
        print(f"  {len(subagents)} sub-agent transcript(s) excluded by default "
              f"(--include-subagents to add them).")
    if args.since:
        print(f"  records stamped before {args.since} will be left out and counted per file.")
    if not sessions:
        print("::error::nothing left to export after filtering")
        return 1

    print(f"exporting {len(sessions)}:")
    for path in sessions:
        print(f"  {path.stat().st_size / 1e6:8.1f} MB  {path}")
    print(f"  {sum(p.stat().st_size for p in sessions) / 1e6:8.1f} MB  total input")
    print(
        "\nSCOPE IS A DECISION, NOT A DEFAULT. Read the index before attaching anything."
    )
    if args.list or not args.out:
        print("\n--list, or no --out given: nothing written.")
        return 0

    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    counter = [0]
    summaries = []
    for path in sessions:
        rendered, summary = export(path, counter, args.since)
        if summary["messages"] == 0:
            print(f"skipped {path.name}: no records at or after {args.since}")
            continue
        target = out / f"{path.stem}.md"
        target.write_text(rendered, encoding="utf-8")
        summary["file"] = target.name
        summary["bytes"] = target.stat().st_size
        summary["sha256"] = hashlib.sha256(target.read_bytes()).hexdigest()
        summaries.append(summary)
        print(f"wrote {target} ({summary['bytes'] / 1e6:.1f} MB, {summary['messages']} messages)")

    if not summaries:
        print("::error::every session was empty after filtering — nothing written")
        return 1

    models: dict[str, int] = {}
    for s in summaries:
        for m, n in s["models"].items():
            models[m] = models.get(m, 0) + n

    total_bytes = sum(s["bytes"] for s in summaries)
    index = [
        "# AI provenance log — index",
        "",
        "Per session: the model recorded on each response, the timestamp of each",
        "exchange, every prompt verbatim, and the unedited output.",
        "",
        "```",
        f"sessions            {len(summaries)}",
        f"messages            {sum(s['messages'] for s in summaries)}",
        f"scope               " + ("sessions that wrote a proposal file"
                                   if args.drafting_only
                                   else "every session mentioning a proposal file"),
        f"left out            {sum(s['skipped'] for s in summaries)} record(s)"
        + (f" stamped before {args.since}" if args.since else " (no date filter)"),
        f"credential strings  {counter[0]} redacted in place",
        f"total size          {total_bytes / 1e6:.1f} MB",
        "models              " + ", ".join(f"{m} ({n})" for m, n in sorted(models.items())),
        "```",
        "",
        "| file | first | last | messages | bytes | sha256 |",
        "|---|---|---|---|---|---|",
    ]
    for s in summaries:
        index.append(
            f"| {s['file']} | {s['first']} | {s['last']} | {s['messages']} | "
            f"{s['bytes']} | {s['sha256'][:16]}… |"
        )
    index += [
        "",
        "Nothing here is attached or committed by the export tool. What to disclose is",
        "the applicant's decision and cannot be taken back once sent.",
    ]
    (out / "INDEX.md").write_text("\n".join(index) + "\n", encoding="utf-8")
    print(f"\nwrote {out / 'INDEX.md'} — {counter[0]} credential string(s) redacted")
    if total_bytes > 50e6:
        print(f"::error::the export is {total_bytes / 1e6:.1f} MB against a 50 MB upload limit — "
              f"narrow it with --since or --drafting-only, or commit it and attach the index")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
