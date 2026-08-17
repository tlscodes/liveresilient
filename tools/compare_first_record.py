"""Compare a captured first record against the chrome120 profile.

WHY A SEPARATE TOOL
`tools/first_record_dump` answers "what bytes does BoringSSL write". This
answers the question those bytes were captured for: does the shape match the
profile the plan targets? Keeping them apart means the capture can be re-parsed
and re-judged later without re-running a build, and the judgement is auditable
on its own.

THE PROFILE IS READ FROM THE DART SOURCE, NOT COPIED
`UtlsClientProfile.chrome120` in
packages/adaptive_transport/lib/src/probe_defense/utls_client_profile.dart is the
single authority for what the target shape is. Transcribing its two lists into
this file would create a second copy that drifts, and a comparison against a
stale copy of the target is worse than no comparison — it would report agreement
with something nobody is building toward.

WHAT "MATCH" MEANS, STATED BEFORE ANY RESULT
A ClientHello's random, session id and key-share bytes differ on every
connection by design, so a byte-for-byte equality of the whole record is not the
test and never could be. The shape is three ordered lists: the cipher suites,
the extension types, and their order. GREASE values are excluded from the
comparison and reported separately, because they are randomised per connection
by design — a profile that uses GREASE cannot be compared on the GREASE values
themselves, only on their presence.

    python3 tools/compare_first_record.py [path/to/FIRST_RECORD.hex]

Exit: 0 when a verdict could be produced (whether or not it is favourable),
1 when the inputs are missing or unparseable — a missing capture is not a
negative result and must not be reported as one.
"""

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROFILE_SRC = os.path.join(
    ROOT, 'packages', 'adaptive_transport', 'lib', 'src', 'probe_defense',
    'utls_client_profile.dart')
# The profile's extensionOrder mixes literals with named constants declared in
# a NEIGHBOURING file (`TlsExtensionType.serverName` and friends). The first
# version of this tool read only the profile file, so six of the fifteen target
# extensions resolved to nothing and the comparison silently ran against a
# nine-entry target. That is the failure this tool's own docstring warns about,
# arriving through the back door — so both files are read, and an unresolved
# name is now a hard error rather than a silent omission.
CONSTANTS_SRC = os.path.join(
    ROOT, 'packages', 'adaptive_transport', 'lib', 'src', 'probe_defense',
    'tls_client_hello.dart')
DEFAULT_HEX = os.path.join(
    ROOT, 'docs', 'TICKET4_FIRST_RECORD', 'FIRST_RECORD.hex')

GREASE = {0x0a0a, 0x1a1a, 0x2a2a, 0x3a3a, 0x4a4a, 0x5a5a, 0x6a6a, 0x7a7a,
          0x8a8a, 0x9a9a, 0xaaaa, 0xbaba, 0xcaca, 0xdada, 0xeaea, 0xfafa}

# The named constants the profile's extensionOrder uses. Their values come from
# the same Dart file, so they are resolved from it rather than assumed here.
NAMED_EXTENSION_RE = re.compile(
    r'static const int (\w+)\s*=\s*(0x[0-9a-fA-F]+|\d+)\s*;')


def u16(b, i):
    return (b[i] << 8) | b[i + 1]


def parse_client_hello(raw):
    """Returns (ciphers, extensions) as integer lists, in wire order."""
    if len(raw) < 5:
        raise ValueError('shorter than a record header: %d bytes' % len(raw))
    if raw[0] != 22:
        raise ValueError('not a handshake record: type %d' % raw[0])
    body = raw[5:5 + u16(raw, 3)]
    if not body or body[0] != 1:
        raise ValueError('not a ClientHello')
    i = 4 + 2 + 32
    i += 1 + body[i]                     # session id
    cs_len = u16(body, i)
    i += 2
    ciphers = [u16(body, i + k) for k in range(0, cs_len, 2)]
    i += cs_len
    i += 1 + body[i]                     # compression methods
    end = i + 2 + u16(body, i)
    i += 2
    extensions = []
    while i + 4 <= end:
        extensions.append(u16(body, i))
        i += 4 + u16(body, i + 2)
    return ciphers, extensions


def read_profile():
    """Reads chrome120's cipher list and extension order from the Dart source."""
    try:
        src = open(PROFILE_SRC, encoding='utf-8').read()
    except OSError as err:
        raise SystemExit('cannot read the profile source: %s' % err)

    names = {m.group(1): int(m.group(2), 0)
             for m in NAMED_EXTENSION_RE.finditer(src)}
    try:
        constants = open(CONSTANTS_SRC, encoding='utf-8').read()
    except OSError as err:
        raise SystemExit('cannot read the extension constants: %s' % err)
    names.update({m.group(1): int(m.group(2), 0)
                  for m in NAMED_EXTENSION_RE.finditer(constants)})

    start = src.index('chrome120 = UtlsClientProfile(')

    def block(field):
        at = src.index('%s: [' % field, start)
        depth = 0
        for j in range(at, len(src)):
            if src[j] == '[':
                depth += 1
            elif src[j] == ']':
                depth -= 1
                if depth == 0:
                    return src[at:j]
        raise SystemExit('unterminated %s list in the profile source' % field)

    def values(field):
        out = []
        for token in re.findall(r'0x[0-9a-fA-F]+|\b\w+\b', block(field)):
            if token in (field, 'int'):
                continue
            if token.startswith('0x'):
                out.append(int(token, 16))
            elif token.isdigit():
                out.append(int(token))
            elif token in names:
                out.append(names[token])
            elif '.' in token:
                continue
        return out

    # Named constants arrive as `TlsExtensionType.serverName`; the regex above
    # already dropped the class qualifier, so resolve the bare member name.
    def extension_values():
        out = []
        unresolved = []
        text = block('extensionOrder')
        # Skip the field name itself, then take every literal and every
        # dotted name in order.
        for token in re.findall(r'0x[0-9a-fA-F]+|[A-Za-z_][\w]*\.[\w]+', text):
            if token.startswith('0x'):
                out.append(int(token, 16))
                continue
            member = token.split('.')[-1]
            if member in names:
                out.append(names[member])
            else:
                unresolved.append(token)
        if unresolved:
            # Loud, because a silently short target list reports agreement
            # with something nobody is building toward.
            raise SystemExit(
                'these names in the profile could not be resolved to values, '
                'so the target list would be incomplete: %s'
                % ', '.join(unresolved))
        return out

    return values('cipherSuites'), extension_values()


def hexlist(values):
    return ' '.join('0x%04x' % v for v in values)


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_HEX
    if not os.path.exists(path):
        print('no capture at %s' % path)
        print('A MISSING CAPTURE IS NOT A NEGATIVE RESULT. Run '
              '`tools/first_record_dump` first; until it produces bytes the '
              'verdict in docs/TICKET4_DECISION.md stays PROVISIONAL.')
        return 1
    raw = bytes.fromhex(open(path, encoding='utf-8').read().strip())
    try:
        ciphers, extensions = parse_client_hello(raw)
    except ValueError as err:
        print('the capture could not be parsed: %s' % err)
        return 1

    want_ciphers, want_extensions = read_profile()
    got_ciphers = [c for c in ciphers if c not in GREASE]
    got_extensions = [e for e in extensions if e not in GREASE]

    print('capture: %s (%d bytes)' % (os.path.relpath(path, ROOT), len(raw)))
    print()
    print('cipher suites')
    print('  target (%2d)  %s' % (len(want_ciphers), hexlist(want_ciphers)))
    print('  captured(%2d)  %s' % (len(got_ciphers), hexlist(got_ciphers)))
    print('  missing      %s'
          % (hexlist([c for c in want_ciphers if c not in got_ciphers]) or '-'))
    print('  extra        %s'
          % (hexlist([c for c in got_ciphers if c not in want_ciphers]) or '-'))
    print('  order        %s'
          % ('identical' if got_ciphers == want_ciphers else 'DIFFERENT'))
    print()
    print('extensions')
    print('  target (%2d)  %s' % (len(want_extensions),
                                  hexlist(want_extensions)))
    print('  captured(%2d)  %s' % (len(got_extensions),
                                   hexlist(got_extensions)))
    print('  missing      %s'
          % (hexlist([e for e in want_extensions
                      if e not in got_extensions]) or '-'))
    print('  extra        %s'
          % (hexlist([e for e in got_extensions
                      if e not in want_extensions]) or '-'))
    print('  order        %s'
          % ('identical' if got_extensions == want_extensions else 'DIFFERENT'))
    print()
    print('grease present: ciphers=%s extensions=%s'
          % (any(c in GREASE for c in ciphers),
             any(e in GREASE for e in extensions)))
    print()

    reproduced = (got_ciphers == want_ciphers
                  and got_extensions == want_extensions)
    if reproduced:
        print('VERDICT: configuration alone reproduces the profile shape. '
              'Section 5 of the decision resolves in favour of BoringSSL.')
    else:
        print('VERDICT: configuration alone does NOT reproduce the profile '
              'shape. Per section 5 that removes the main reason for choosing '
              'BoringSSL, and the choice moves to wolfSSL with its licence '
              'cost — unless the gap above is closable by further '
              'configuration, which the lists say exactly.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
