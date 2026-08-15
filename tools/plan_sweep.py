"""Sweep the whole repository against a plan document.

Four questions, answered mechanically:

  ANCHOR   every `path:line` the plan cites -- does the file exist, is the
           line still in range, and what does that line actually say now?
  BUILT    every identifier the plan names -- is it already in the tree?
  DEAD     an identifier that exists but is written and never read outside
           its own declaration and the tests (the `iceFailureCount` class
           of defect).
  ORPHAN   a source file inside a package the plan touches that the plan
           never mentions -- work that exists and was missed.

Usage:  python3 tools/plan_sweep.py docs/PLAN_five_tickets_v4.md
"""

import os
import re
import sys
from collections import defaultdict

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# identifiers that are language/common words, not project symbols
STOPWORDS = {
    'true', 'false', 'null', 'final', 'const', 'class', 'void', 'this',
    'return', 'import', 'export', 'static', 'async', 'await', 'Future',
    'String', 'double', 'bool', 'List', 'Map', 'Set', 'int', 'num',
    'dart', 'lib', 'src', 'test', 'main', 'index', 'data', 'value',
    'name', 'type', 'error', 'result', 'config', 'flutter', 'package',
    'pubspec', 'yaml', 'json', 'http', 'https', 'grep', 'exit', 'PASS',
    'FAIL', 'TODO', 'NOTE', 'STATUS', 'BLOCKER', 'SLOT', 'REVIEW',
    'JUDGED', 'UNJUDGED', 'regression', 'moment', 'delta',
}

ANCHOR_RE = re.compile(r'([\w./-]+\.dart):(\d+)(?:-(\d+))?')
TICK_RE = re.compile(r'`([^`\n]{2,120})`')
IDENT_RE = re.compile(r'\b([A-Za-z_][A-Za-z0-9_]{3,})\b')
WORD = lambda s: re.compile(r'\b' + re.escape(s) + r'\b')

DECL_PATTERNS = [
    r'\bclass\s+{s}\b', r'\benum\s+{s}\b', r'\bmixin\s+{s}\b',
    r'\bextension\s+{s}\b', r'\btypedef\s+{s}\b',
    r'\b(?:final|const|late|var|static)\b[^;=]*\b{s}\s*[=;]',
    r'^\s*[\w<>?,\s\[\]]+\s{s}\s*\(',
]


def source_files():
    out = []
    for base in ('packages', 'apps', 'integration_test'):
        top = os.path.join(ROOT, base)
        for dirpath, dirnames, filenames in os.walk(top):
            dirnames[:] = [d for d in dirnames
                           if not d.startswith('.') and d != 'build']
            for fn in filenames:
                if fn.endswith('.dart'):
                    out.append(os.path.relpath(
                        os.path.join(dirpath, fn), ROOT))
    return sorted(out)


def is_test(rel):
    return '/test/' in rel or rel.endswith('_test.dart') or '/support/' in rel


def read(rel):
    try:
        with open(os.path.join(ROOT, rel), encoding='utf-8') as fh:
            return fh.read()
    except (OSError, UnicodeDecodeError):
        return ''


def main(plan_rel):
    plan = read(plan_rel)
    if not plan:
        print('cannot read plan:', plan_rel)
        return 1
    plan_lines = plan.splitlines()

    files = source_files()
    bodies = {rel: read(rel) for rel in files}
    prod = [r for r in files if not is_test(r)]

    # ---------- ANCHOR ----------
    print('=' * 78)
    print('ANCHOR  -- plan cites file:line')
    print('=' * 78)
    seen = set()
    stale = 0
    for lineno, text in enumerate(plan_lines, 1):
        for m in ANCHOR_RE.finditer(text):
            path, start = m.group(1), int(m.group(2))
            key = (path, start)
            if key in seen:
                continue
            seen.add(key)
            hits = [r for r in files if r.endswith(path.lstrip('./'))]
            if not hits:
                print('  MISSING FILE  plan:%-5d %s:%d' % (lineno, path, start))
                stale += 1
                continue
            rel = hits[0]
            src = bodies[rel].splitlines()
            if start > len(src):
                print('  LINE PAST EOF plan:%-5d %s:%d (file has %d)'
                      % (lineno, rel, start, len(src)))
                stale += 1
            else:
                body = src[start - 1].strip()
                print('  ok            plan:%-5d %s:%d  | %s'
                      % (lineno, rel, start, body[:64]))
    print('  --> anchors checked: %d, stale: %d' % (len(seen), stale))

    # ---------- symbols ----------
    cands = set()
    for m in TICK_RE.finditer(plan):
        chunk = m.group(1)
        if chunk.endswith('.dart') or '/' in chunk:
            continue
        for ident in IDENT_RE.findall(chunk):
            if ident not in STOPWORDS and not ident.isupper():
                cands.add(ident)

    built, missing, dead = [], [], []
    for sym in sorted(cands):
        pat = WORD(sym)
        prod_files = [r for r in prod if pat.search(bodies[r])]
        if not prod_files:
            missing.append(sym)
            continue
        total = sum(len(pat.findall(bodies[r])) for r in prod_files)
        declared_in = []
        for r in prod_files:
            for dp in DECL_PATTERNS:
                if re.search(dp.replace('{s}', re.escape(sym)),
                             bodies[r], re.M):
                    declared_in.append(r)
                    break
        if declared_in and total <= len(declared_in):
            dead.append((sym, declared_in, total))
        else:
            built.append((sym, len(prod_files), total))

    print()
    print('=' * 78)
    print('BUILT   -- named by the plan and already present in the tree')
    print('=' * 78)
    for sym, nf, total in built:
        print('  %-34s %2d file(s)  %3d ref(s)' % (sym, nf, total))

    print()
    print('=' * 78)
    print('DEAD    -- present but referenced only where it is declared')
    print('=' * 78)
    if not dead:
        print('  (none)')
    for sym, where, total in dead:
        print('  %-34s %d ref(s)  %s' % (sym, total, ', '.join(where)))

    print()
    print('=' * 78)
    print('ABSENT  -- named by the plan, not in the tree (expected for new work)')
    print('=' * 78)
    print(' ', ', '.join(missing) if missing else '(none)')

    # ---------- ORPHAN ----------
    touched = set()
    for rel in prod:
        parts = rel.split('/')
        if parts[0] == 'packages' and len(parts) > 1:
            touched.add(parts[1]) if ('packages/%s/' % parts[1]) in plan else None
    for rel in prod:
        if rel.split('/')[0] == 'apps' and rel in plan:
            touched.add('apps')

    # topic vocabulary, derived from the plan itself -- no hand-written list
    vocab = set()
    for sym in cands:
        for part in re.findall(r'[A-Z]?[a-z]{3,}', sym):
            vocab.add(part.lower())
    for extra in ('dtx', 'cbr', 'silence', 'jitter', 'shaping', 'shaper',
                  'revision', 'manifest', 'quantile', 'admission', 'refuse',
                  'redirect', 'resolver', 'bandwidth', 'occupancy', 'ptime'):
        vocab.add(extra)
    vocab -= {'name', 'value', 'file', 'line', 'test', 'call', 'this',
              'that', 'from', 'with', 'into', 'each', 'code', 'data'}

    # IDF: a term present in most files carries no signal. Boilerplate like
    # "for" / "future" / "config" is eliminated by its own frequency, so no
    # hand-maintained noise list is needed.
    lowered = {rel: bodies[rel].lower() for rel in prod}
    import math
    n_docs = len(prod)
    idf = {}
    for term in vocab:
        df = sum(1 for rel in prod if term in lowered[rel])
        if df == 0 or df > n_docs * 0.4:
            continue
        idf[term] = math.log(n_docs / df)

    orphans = []
    for rel in prod:
        parts = rel.split('/')
        pkg = parts[1] if parts[0] == 'packages' and len(parts) > 1 else parts[0]
        if pkg not in touched:
            continue
        if os.path.basename(rel) in plan or rel in plan:
            continue
        low = lowered[rel]
        hits = sorted(((idf[t], t) for t in idf if t in low), reverse=True)
        score = sum(w for w, _ in hits)
        orphans.append((round(score, 1), rel, pkg,
                        [t for _, t in hits], len(low.splitlines())))
    orphans.sort(reverse=True)

    print()
    print('=' * 78)
    print('ORPHAN  -- exists, sits in a package the plan touches, plan never')
    print('           names it. Ranked by overlap with the plan vocabulary.')
    print('=' * 78)
    if not orphans:
        print('  (none)')
    for score, rel, pkg, hits, nlines in orphans[:24]:
        if score < 4:
            break
        print('  [%2d] %-68s %4dL' % (score, rel, nlines))
        print('       %s' % ', '.join(hits[:14]))
    print()
    print('  --> %d orphan file(s) total; showing those scoring >= 4'
          % len(orphans))
    print('  --> tool limit: it finds symbols never REFERENCED. A symbol that')
    print('      is passed but never WRITTEN (the iceFailureCount defect) has')
    print('      references and will not appear under DEAD.')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1
                  else 'docs/PLAN_five_tickets_v4.md'))
