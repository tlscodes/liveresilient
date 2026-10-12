#!/usr/bin/env python3
"""Parse the JS worker's answer packets with the PROVEN Python client codec.

The Dart client mirrors this codec, so if parse_dns_answer_packet + unframe_down
read the JS answers and reassemble the exact give response the fixture expects,
the worker speaks the wire the real locked-phone client speaks. Closes the loop
the node test opened (it drove the server; this reads it back as the client).
"""
import base64
import json
import os
import sys

T2 = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "t2"))
sys.path.insert(0, T2)

from txt_query_wire import parse_dns_answer_packet, unframe_down  # noqa: E402

here = os.path.dirname(__file__)
fixture = json.load(open(os.path.join(here, "give_fixture.json")))
js = json.load(open(os.path.join(here, "js_answers.json")))

expected = {c["name"]: base64.b64decode(c["give_response_b64"]) for c in fixture["cases"]}

failed = 0
for case in js["cases"]:
    name = case["name"]
    acc = b""
    for hexpkt in case["answers"]:
        ans = parse_dns_answer_packet(bytes.fromhex(hexpkt))
        if ans.rcode != 0 or ans.payload is None:
            continue
        acc += unframe_down(ans.payload)
    want = expected[name]
    ok = acc == want
    print(f"{'PASS' if ok else 'FAIL'} {name}: {len(acc)} bytes reassembled, want {len(want)}")
    if not ok:
        failed += 1

if failed:
    print(f"{failed} case(s) failed")
    sys.exit(1)
print("all cases: JS worker answers parse byte-for-byte with the proven client codec")
