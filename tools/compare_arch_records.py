#!/usr/bin/env python3
"""Compare two recorded first records that were composed on different machines.

WHY NOT A DIFF
An empty diff is the wrong predicate here, and not because of tolerance: the
configuration under measurement deliberately permutes its extension order per
connection and fills several fields with fresh random bytes, so two runs on the
SAME machine already differ byte for byte. Demanding equality would fail honest
runs; loosening equality until it passed would measure nothing.

THE PREDICATE
Equality over a declared projection of the fields that do not depend on the
machine, AND a positive assertion that the candidate really was composed on the
architecture being claimed. The second half matters as much as the first: with
only the first, a second run on the host would pass as a run on the phone, which
is precisely the claim at issue.

The projection is a committed file, not a flag, so widening it is a reviewed
change with a reason attached rather than something that happens at 2 a.m. to
make a red turn green.

Record file format — plain text, provenance first, one hex line last:
    arch: arm64
    host: <machine or device name>
    date: 2026-08-18T00:00:00Z
    source: <what produced it>
    pin: <the backend revision it was composed with>
    hex: 16030100...

Exit codes: 0 equal under the projection, 1 a difference or a failed provenance
assertion, 2 unusable input.
"""

from __future__ import annotations

import argparse
import json
import sys

GREASE = {0x0a0a, 0x1a1a, 0x2a2a, 0x3a3a, 0x4a4a, 0x5a5a, 0x6a6a, 0x7a7a,
          0x8a8a, 0x9a9a, 0xaaaa, 0xbaba, 0xcaca, 0xdada, 0xeaea, 0xfafa}


def u16(b, i):
    return (b[i] << 8) | b[i + 1]


def read_record(path):
    """Returns (headers, raw_bytes)."""
    headers, hexdigits = {}, None
    try:
        with open(path, encoding='utf-8') as handle:
            for line in handle:
                line = line.strip()
                if not line or line.startswith('#'):
                    continue
                if ':' not in line:
                    raise SystemExit(f'{path}: line without a key: {line[:40]!r}')
                key, value = line.split(':', 1)
                key, value = key.strip(), value.strip()
                if key == 'hex':
                    hexdigits = value
                else:
                    headers[key] = value
    except OSError as exc:
        raise SystemExit(f'{path}: {exc}')
    if hexdigits is None:
        raise SystemExit(f'{path}: no hex line')
    try:
        raw = bytes.fromhex(hexdigits)
    except ValueError as exc:
        raise SystemExit(f'{path}: hex line is not hex: {exc}')
    for required in ('arch', 'date', 'source'):
        if required not in headers:
            raise SystemExit(f'{path}: missing provenance header {required!r}')
    return headers, raw


def parse(raw, path):
    """Returns the fields this tool can compare, from one record."""
    if len(raw) < 5 or raw[0] != 22:
        raise SystemExit(f'{path}: not a handshake record')
    body = raw[5:5 + u16(raw, 3)]
    if not body or body[0] != 1:
        raise SystemExit(f'{path}: not the first handshake message')
    out = {'record_version': u16(raw, 1), 'legacy_version': u16(body, 4)}
    i = 4 + 2 + 32
    session_id_len = body[i]
    out['session_id_len'] = session_id_len
    i += 1 + session_id_len
    cs_len = u16(body, i)
    i += 2
    out['ciphers'] = [u16(body, i + k) for k in range(0, cs_len, 2)]
    i += cs_len
    comp_len = body[i]
    out['compression'] = list(body[i + 1:i + 1 + comp_len])
    i += 1 + comp_len
    end = i + 2 + u16(body, i)
    i += 2
    extensions = {}
    order = []
    while i + 4 <= end:
        ext_id, ext_len = u16(body, i), u16(body, i + 2)
        extensions[ext_id] = body[i + 4:i + 4 + ext_len]
        order.append(ext_id)
        i += 4 + ext_len
    out['extensions'] = extensions
    out['extension_order'] = order
    return out


def strip_grease(values):
    return [v for v in values if v not in GREASE]


def projection_of(parsed, projection):
    """The machine-independent view, exactly as the projection file declares."""
    view = {}
    for field in projection['invariant_fields']:
        if field == 'record_version':
            view[field] = parsed['record_version']
        elif field == 'legacy_version':
            view[field] = parsed['legacy_version']
        elif field == 'cipher_suites_in_order':
            view[field] = strip_grease(parsed['ciphers'])
        elif field == 'compression_methods':
            view[field] = parsed['compression']
        elif field == 'extension_set':
            view[field] = sorted(strip_grease(parsed['extension_order']))
        elif field == 'extension_count':
            view[field] = len(parsed['extension_order'])
        else:
            raise SystemExit(f'projection names an unknown field: {field}')
    payloads = {}
    for ext_id in projection['invariant_extension_payloads']:
        blob = parsed['extensions'].get(int(ext_id))
        payloads[str(ext_id)] = None if blob is None else blob.hex()
    view['extension_payloads'] = payloads
    return view


def main():
    parser = argparse.ArgumentParser(
        description='compare two first records under a declared projection')
    parser.add_argument('--baseline', required=True)
    parser.add_argument('--candidate', required=True)
    parser.add_argument('--projection', required=True)
    parser.add_argument('--require-arch', required=True,
                        help='the architecture the candidate must declare')
    args = parser.parse_args()

    try:
        with open(args.projection, encoding='utf-8') as handle:
            projection = json.load(handle)
    except (OSError, ValueError) as exc:
        raise SystemExit(f'{args.projection}: {exc}')
    for key in ('invariant_fields', 'invariant_extension_payloads', 'variant_fields'):
        if key not in projection:
            raise SystemExit(f'{args.projection}: missing {key!r}')

    base_headers, base_raw = read_record(args.baseline)
    cand_headers, cand_raw = read_record(args.candidate)

    failures = []

    # The provenance half. A candidate that does not say what it must, or a
    # baseline recorded on the same architecture, makes the comparison
    # meaningless however well the bytes agree.
    if cand_headers['arch'] != args.require_arch:
        failures.append(f'candidate declares arch {cand_headers["arch"]!r}, '
                        f'required {args.require_arch!r}')
    if base_headers['arch'] == cand_headers['arch']:
        failures.append(f'baseline and candidate were both composed on '
                        f'{base_headers["arch"]!r} — that is one architecture, not two')
    if base_headers.get('pin') and cand_headers.get('pin') and \
            base_headers['pin'][:8] != cand_headers['pin'][:8]:
        failures.append(f'different backend revisions: baseline {base_headers["pin"]}, '
                        f'candidate {cand_headers["pin"]}')

    base_view = projection_of(parse(base_raw, args.baseline), projection)
    cand_view = projection_of(parse(cand_raw, args.candidate), projection)

    for field in sorted(set(base_view) | set(cand_view)):
        if base_view.get(field) != cand_view.get(field):
            if field == 'extension_payloads':
                for ext in sorted(set(base_view[field]) | set(cand_view[field])):
                    if base_view[field].get(ext) != cand_view[field].get(ext):
                        failures.append(
                            f'extension 0x{int(ext):04x} payload differs:\n'
                            f'    baseline:  {base_view[field].get(ext)}\n'
                            f'    candidate: {cand_view[field].get(ext)}')
            else:
                failures.append(f'{field} differs:\n'
                                f'    baseline:  {base_view.get(field)}\n'
                                f'    candidate: {cand_view.get(field)}')

    print(f'baseline:  {args.baseline}  arch={base_headers["arch"]} '
          f'bytes={len(base_raw)}')
    print(f'candidate: {args.candidate}  arch={cand_headers["arch"]} '
          f'bytes={len(cand_raw)}')
    print(f'projection: {args.projection} — '
          f'{len(projection["invariant_fields"])} fields, '
          f'{len(projection["invariant_extension_payloads"])} extension payloads')
    print('variant by declaration, not compared: '
          + ', '.join(projection['variant_fields']))
    if failures:
        print()
        for failure in failures:
            print(f'DIFFERENCE  {failure}')
        print(f'\nARCH COMPARE FAILED — {len(failures)} difference(s)')
        return 1
    print(f'\nARCH COMPARE PASSED — the projection is identical and the candidate '
          f'declares {args.require_arch}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
