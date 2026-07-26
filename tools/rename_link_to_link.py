#!/usr/bin/env python3
"""Rename link -> link across the repo (identifiers, filenames, prose)."""
import os
import re
import subprocess

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SKIP_DIRS = {'.git', 'build', '.dart_tool', '.backups', 'node_modules'}
EXTS = {'.dart', '.md', '.yaml', '.yml', '.py', '.json', '.sh', '.txt'}
PAT = re.compile(r'link', re.IGNORECASE)


def repl(m):
    s = m.group(0)
    return 'Link' if s[0].isupper() else ('LINK' if s.isupper() else 'link')


changed, renamed = [], []
for dirpath, dirnames, filenames in os.walk(ROOT):
    dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
    for fn in filenames:
        if os.path.splitext(fn)[1] not in EXTS:
            continue
        p = os.path.join(dirpath, fn)
        try:
            src = open(p, encoding='utf-8').read()
        except (UnicodeDecodeError, OSError):
            continue
        out = PAT.sub(repl, src)
        if out != src:
            open(p, 'w', encoding='utf-8').write(out)
            changed.append(os.path.relpath(p, ROOT))
        if PAT.search(fn):
            new = os.path.join(dirpath, PAT.sub(repl, fn))
            subprocess.run(['git', 'mv', p, new], cwd=ROOT, check=False)
            if not os.path.exists(new):
                os.rename(p, new)
            renamed.append((os.path.relpath(p, ROOT), os.path.relpath(new, ROOT)))

print(f'content-changed: {len(changed)}')
for c in changed:
    print('  ', c)
print(f'renamed: {len(renamed)}')
for a, b in renamed:
    print(f'   {a} -> {b}')
