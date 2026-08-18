#!/usr/bin/env python3
"""Read the remaining-work plan, validate it strictly, say which step is next.

This script runs NOTHING. It cannot tell you that a step passed, only that the
evidence a step named exists — so every state it prints for a finished step is
qualified `done (unverified)`, and the command that would actually prove it is
printed beside it. That restraint is the whole point: the plan file owns the
definition of proof, the suite scripts own the proving, and this tool owns
neither.

Design consulted with Fable 5 (single-topic, 2026-08-18); typed here.

Exit codes
  0  well formed; either a runnable step was identified or all are done
  1  well formed but inconsistent — a dangling reference, a zero-byte evidence
     file, or a verify_cmd that disagrees with the unattended runner's copy
  2  parse or schema error — anything the parser did not fully understand
"""

from __future__ import annotations

import argparse
import datetime
import heapq
import json
import os
import re
import sys
from dataclasses import dataclass, field

PLAN_DEFAULT = 'docs/PLAN_REMAINING.md'
BACKLOG_DEFAULT = 'docs/gate_backlog.json'
RUNJSON_DEFAULT = '.autorun/run.json'

KINDS = ('unattended', 'attended', 'atomic-migration')
REQUIRED = ('step', 'id', 'title', 'kind', 'needs', 'verify_cmd', 'evidence')
OPTIONAL = ('attended_cmd', 'closes', 'blocked_ref', 'blocked_by', 'slot', 'rollback')
ALLOWED_FIELDS = set(REQUIRED) | set(OPTIONAL)
LIST_FIELDS = ('needs', 'evidence', 'closes')
ID_RE = re.compile(r'^[a-z0-9][a-z0-9-]*$')
REF_RE = re.compile(r'^docs/gate_backlog\.json#\S+$')
# Recognisable YAML that this restricted parser deliberately refuses, so the
# refusal can name what it saw rather than shrugging at "malformed".
YAML_BEYOND_SUBSET = (
    ('|', 'block scalars'), ('>', 'folded scalars'),
    ('&', 'anchors'), ('*', 'aliases'),
    ('[', 'flow sequences'), ('{', 'flow mappings'),
)


@dataclass
class Error:
    severity: int          # 2 = schema/parse, 1 = inconsistency
    where: str
    msg: str


@dataclass
class Step:
    step: int
    id: str
    title: str
    kind: str
    needs: list
    verify_cmd: str
    evidence: list
    lineno: int
    attended_cmd: str = ''
    closes: list = field(default_factory=list)
    blocked_ref: str = ''
    blocked_by: str = ''
    slot: str = ''
    rollback: str = ''


def extract_blocks(text, path):
    """Fenced ```yaml blocks, found by a line state machine.

    A multiline regex would swallow everything between the first and last fence
    in the file, which is the failure mode that reads as one enormous valid
    block. Every ```yaml block must be a step; a plan that wants a block the
    schema does not describe tags it with another language.
    """
    blocks, errors, cur, start = [], [], None, 0
    for n, line in enumerate(text.splitlines(), 1):
        stripped = line.strip()
        if cur is None:
            if stripped == '```yaml':
                cur, start = [], n
        elif stripped == '```':
            blocks.append((start, cur))
            cur = None
        else:
            cur.append((n, line))
    if cur is not None:
        errors.append(Error(2, f'{path}:{start}', 'fenced yaml block is never closed'))
    if not blocks:
        errors.append(Error(2, path, 'no yaml step blocks found — an empty plan is a parse failure'))
    return blocks, errors


def parse_block(start, lines, path):
    """The restricted parser: scalars and simple lists, nothing else."""
    out, errors, cur_list = {}, [], None
    for n, raw in lines:
        line = raw.rstrip()
        where = f'{path}:{n}'
        if not line.strip() or line.strip().startswith('#'):
            continue
        if line.strip().startswith('- '):
            if cur_list is None:
                errors.append(Error(2, where, 'list item outside any list'))
                continue
            out[cur_list].append(_unquote(line.strip()[2:].strip()))
            continue
        m = re.match(r'^([A-Za-z_][A-Za-z0-9_]*):(.*)$', line)
        if not m:
            errors.append(Error(2, where, f'malformed line: {line.strip()[:60]!r}'))
            continue
        key, rest = m.group(1), m.group(2).strip()
        if key in out:
            errors.append(Error(2, where, f'duplicate key {key!r} in one block'))
            continue
        if rest == '':
            out[key], cur_list = [], key
            continue
        if rest == '[]':
            # The one flow form allowed, because a block list cannot express
            # "empty" and a required field must not be omitted to mean it.
            out[key], cur_list = [], None
            continue
        for token, name in YAML_BEYOND_SUBSET:
            if rest.startswith(token):
                errors.append(Error(2, where, f'valid YAML but outside the plan schema ({name} not supported)'))
                break
        else:
            out[key] = _unquote(rest)
            cur_list = None
    return out, errors


def _unquote(value):
    if len(value) >= 2 and value[0] == value[-1] and value[0] in ('"', "'"):
        return value[1:-1]
    if re.fullmatch(r'-?\d+', value):
        return int(value)
    return value


def _is_iso_date(value):
    try:
        datetime.date.fromisoformat(str(value))
        return True
    except ValueError:
        return False


def validate_step(raw, lineno, path):
    errors, where = [], f'{path}:{lineno}'
    for key in raw:
        if key not in ALLOWED_FIELDS:
            errors.append(Error(2, where, f'unknown field {key!r} — a typo must not silently disable a check'))
    for key in REQUIRED:
        if key not in raw:
            errors.append(Error(2, where, f'missing required field {key!r}'))
    if errors:
        return None, errors
    if not isinstance(raw['step'], int):
        errors.append(Error(2, where, 'step must be an integer'))
    if not ID_RE.match(str(raw['id'])):
        errors.append(Error(2, where, f'id {raw["id"]!r} is not a slug'))
    if raw['kind'] not in KINDS:
        errors.append(Error(2, where, f'kind {raw["kind"]!r} is not one of {KINDS}'))
    for key in LIST_FIELDS:
        if key in raw and not isinstance(raw[key], list):
            errors.append(Error(2, where, f'{key} must be a list'))
    if isinstance(raw.get('evidence'), list) and not raw['evidence']:
        errors.append(Error(2, where, 'evidence is empty — a step with no evidence would be trivially done'))
    if (raw['kind'] == 'attended') != bool(raw.get('attended_cmd')):
        errors.append(Error(2, where, 'attended_cmd is required for kind attended, and forbidden otherwise'))
    if (raw['kind'] == 'atomic-migration') != bool(raw.get('rollback')):
        errors.append(Error(2, where, 'rollback is required for kind atomic-migration, and forbidden otherwise'))
    if bool(raw.get('blocked_by')) != bool(raw.get('slot')):
        errors.append(Error(2, where, 'blocked_by and slot are required together'))
    for key in ('slot',):
        if raw.get(key) and not _is_iso_date(raw[key]):
            errors.append(Error(2, where, f'{key} must be an absolute ISO date, never a relative word'))
    if raw.get('blocked_by') and not re.search(r'\d{4}-\d{2}-\d{2}', str(raw['blocked_by'])):
        errors.append(Error(2, where, 'blocked_by must carry an absolute ISO date'))
    if raw.get('blocked_ref') and not REF_RE.match(str(raw['blocked_ref'])):
        errors.append(Error(2, where, 'blocked_ref must look like docs/gate_backlog.json#<id>'))
    if errors:
        return None, errors
    known = {k: v for k, v in raw.items() if k in ALLOWED_FIELDS}
    known.setdefault('closes', [])
    return Step(lineno=lineno, **known), []


def validate_graph(steps, path):
    errors, ids, numbers = [], {}, {}
    for s in steps:
        if s.id in ids:
            errors.append(Error(2, f'{path}:{s.lineno}', f'duplicate id {s.id!r}'))
        ids[s.id] = s
        if s.step in numbers:
            errors.append(Error(2, f'{path}:{s.lineno}', f'duplicate step number {s.step}'))
        numbers[s.step] = s
    for s in steps:
        for need in s.needs:
            if need not in ids:
                errors.append(Error(2, f'{path}:{s.lineno}', f'needs unknown id {need!r}'))
    return errors


def topo_order(steps, path):
    """Kahn with a min-heap on step number: dependency order decides, the number
    only breaks ties, so the order is deterministic across machines."""
    by_id = {s.id: s for s in steps}
    indegree = {s.id: len([n for n in s.needs if n in by_id]) for s in steps}
    dependents = {s.id: [] for s in steps}
    for s in steps:
        for need in s.needs:
            if need in by_id:
                dependents[need].append(s.id)
    heap = [(by_id[i].step, i) for i, d in indegree.items() if d == 0]
    heapq.heapify(heap)
    order = []
    while heap:
        _, sid = heapq.heappop(heap)
        order.append(by_id[sid])
        for dep in dependents[sid]:
            indegree[dep] -= 1
            if indegree[dep] == 0:
                heapq.heappush(heap, (by_id[dep].step, dep))
    if len(order) != len(steps):
        left = [s.id for s in steps if s not in order]
        return [], [Error(2, path, f'needs form a cycle among {sorted(left)} — dependency order is undefined')]
    return order, []


def check_backlog(steps, backlog_path):
    referenced = [s for s in steps if s.blocked_ref or s.closes]
    if not referenced:
        return [], None
    if not os.path.exists(backlog_path):
        return [Error(1, backlog_path, 'referenced by the plan but not present')], None
    try:
        with open(backlog_path, encoding='utf-8') as handle:
            data = json.load(handle)
    except (OSError, ValueError) as exc:
        return [Error(1, backlog_path, f'unreadable: {exc}')], None
    known = set()
    for value in data.values():
        if isinstance(value, dict):
            known |= set(value.keys())
        elif isinstance(value, list):
            known |= {str(item) for item in value}
    errors = []
    for s in referenced:
        if s.blocked_ref:
            item = s.blocked_ref.split('#', 1)[1]
            if item not in known:
                errors.append(Error(1, s.id, f'blocked_ref names {item!r}, absent from the backlog'))
        for item in s.closes:
            if item not in known:
                errors.append(Error(1, s.id, f'closes {item!r}, absent from the backlog'))
    return errors, known


def check_run_json(steps, run_path):
    if not os.path.exists(run_path):
        return [], 'run.json not present, cross-check skipped'
    try:
        with open(run_path, encoding='utf-8') as handle:
            data = json.load(handle)
    except (OSError, ValueError) as exc:
        return [Error(1, run_path, f'unreadable: {exc}')], None
    runners = {}
    for entry in data.get('steps', []):
        if isinstance(entry, dict) and 'id' in entry:
            runners[str(entry['id'])] = entry.get('verify_cmd', '')
    errors = []
    for s in steps:
        if s.id in runners and runners[s.id] != s.verify_cmd:
            errors.append(Error(1, s.id, 'verify_cmd differs from the runner state\n'
                                         f'    plan:   {s.verify_cmd}\n'
                                         f'    runner: {runners[s.id]}'))
    return errors, f'{len(runners)} runner step(s) cross-checked'


def compute_states(order):
    """Existence of a non-empty evidence file is the only status signal."""
    states, errors, missing = {}, [], {}
    for s in order:
        absent = []
        for path in s.evidence:
            if not os.path.exists(path):
                absent.append(path)
            elif os.path.getsize(path) == 0:
                absent.append(path)
                errors.append(Error(1, s.id, f'evidence {path} exists but is empty — counted missing'))
        missing[s.id] = absent
        needs_done = all(states.get(n) == 'done' for n in s.needs)
        if not absent and needs_done:
            states[s.id] = 'done'
        elif s.blocked_by or s.blocked_ref:
            states[s.id] = 'blocked'
        elif s.kind == 'attended' and absent and needs_done:
            states[s.id] = 'awaiting_evidence'
        elif needs_done:
            states[s.id] = 'ready'
        else:
            states[s.id] = 'pending'
    return states, errors, missing


def report(order, states, missing, errors, notes, plan_path):
    print(f'plan: {plan_path}')
    for note in notes:
        if note:
            print(f'note: {note}')
    print()
    print(f'{"#":>2}  {"id":<28} {"kind":<17} state')
    for s in order:
        print(f'{s.step:>2}  {s.id:<28} {s.kind:<17} '
              f'{states[s.id] + (" (unverified)" if states[s.id] == "done" else "")}')
    for s in order:
        if missing.get(s.id):
            print(f'\nmissing evidence for {s.id}:')
            for path in missing[s.id]:
                print(f'  {path}')
    if errors:
        print()
        for err in sorted(errors, key=lambda e: -e.severity):
            label = 'ERROR' if err.severity == 2 else 'INCONSISTENT'
            print(f'{label}  {err.where}: {err.msg}')
    nxt = next((s for s in order if states[s.id] in ('ready', 'awaiting_evidence')), None)
    if nxt is not None:
        print(f'\nNEXT STEP: {nxt.id} — {nxt.title}')
        print(f'  state:   {states[nxt.id]}')
        print(f'  verify:  {nxt.verify_cmd}')
        if nxt.attended_cmd:
            print(f'  human:   {nxt.attended_cmd}')
    return nxt


def main():
    parser = argparse.ArgumentParser(description='validate the remaining-work plan and name the next step')
    parser.add_argument('--plan', default=PLAN_DEFAULT)
    parser.add_argument('--backlog', default=BACKLOG_DEFAULT)
    parser.add_argument('--run-json', default=RUNJSON_DEFAULT)
    args = parser.parse_args()

    try:
        with open(args.plan, encoding='utf-8') as handle:
            text = handle.read()
    except OSError as exc:
        print(f'ERROR  {args.plan}: {exc}')
        print('PLAN INVALID: 1 schema error, 0 inconsistencies (see above)')
        return 2

    blocks, errors = extract_blocks(text, args.plan)
    steps = []
    for start, lines in blocks:
        raw, perrs = parse_block(start, lines, args.plan)
        errors += perrs
        if perrs:
            continue
        step, verrs = validate_step(raw, start, args.plan)
        errors += verrs
        if step is not None:
            steps.append(step)
    errors += validate_graph(steps, args.plan)

    schema_errors = [e for e in errors if e.severity == 2]
    if schema_errors or not steps:
        for err in sorted(errors, key=lambda e: -e.severity):
            label = 'ERROR' if err.severity == 2 else 'INCONSISTENT'
            print(f'{label}  {err.where}: {err.msg}')
        print(f'PLAN INVALID: {len(schema_errors)} schema error(s), '
              f'{len(errors) - len(schema_errors)} inconsistency(ies) (see above)')
        return 2

    order, cycle_errors = topo_order(steps, args.plan)
    if cycle_errors:
        for err in cycle_errors:
            print(f'ERROR  {err.where}: {err.msg}')
        print('PLAN INVALID: 1 schema error(s), 0 inconsistency(ies) (see above)')
        return 2

    backlog_errors, _ = check_backlog(steps, args.backlog)
    run_errors, run_note = check_run_json(steps, args.run_json)
    states, state_errors, missing = compute_states(order)
    errors += backlog_errors + run_errors + state_errors

    nxt = report(order, states, missing, errors, [run_note], args.plan)
    inconsistencies = [e for e in errors if e.severity == 1]
    done = sum(1 for s in order if states[s.id] == 'done')
    print()
    if inconsistencies:
        print(f'PLAN INCONSISTENT: {len(inconsistencies)} inconsistency(ies) (see above), 0 schema errors')
        return 1
    if nxt is not None:
        print(f'PLAN OK: {len(order)} steps, {done} done (unverified), '
              f'next={nxt.id} (step {nxt.step}), verify: {nxt.verify_cmd}')
    elif done == len(order):
        print(f'PLAN OK: all {len(order)} steps done (unverified — this tool runs nothing)')
    else:
        blocked = sum(1 for s in order if states[s.id] == 'blocked')
        print(f'PLAN OK: no runnable step — {blocked} blocked, {done}/{len(order)} done (unverified)')
    return 0


if __name__ == '__main__':
    sys.exit(main())
