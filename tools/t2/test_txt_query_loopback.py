#!/usr/bin/env python3
"""Gate 2 — real UDP/53 on loopback under 16 kbit/s shaping. Design §7.2.

Prints a measured number. No claim that 'the valve works' without that number.
"""

from __future__ import annotations

import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

from txt_query_client import TxtQueryClient  # noqa: E402
from txt_query_server import TxtQueryServer  # noqa: E402

DOMAIN = "example.test"
SHAPE_BPS = 16_000
PORT = 0
failures = 0


def check(name: str, ok: bool, detail: str = "") -> int:
    status = "PASS" if ok else "FAIL"
    extra = f" {detail}" if detail else ""
    print(f"  {status} {name}{extra}")
    return 0 if ok else 1


def main() -> int:
    global failures
    print("gate_loopback")
    with TxtQueryServer(DOMAIN, host="127.0.0.1", port=PORT, echo=True, rate_bps=SHAPE_BPS) as srv:
        time.sleep(0.05)
        with TxtQueryClient(DOMAIN, server=("127.0.0.1", srv.port), timeout_s=5.0) as cli:
            samples = []
            for n in (29, 54):
                payload = bytes((i * 17) % 256 for i in range(n))
                t0 = time.perf_counter()
                session, echoed = cli.send(payload)
                rtt = time.perf_counter() - t0
                failures += check(f"echo {n}B", echoed == payload, f"rtt={rtt:.4f}s")
                samples.append((n, rtt))
            idle = cli.poll(session)
            failures += check("idle poll empty", idle == b"")
            queries = cli.attempts

    r29 = samples[0][1]
    r54 = samples[1][1]
    total_bytes = sum(n for n, _ in samples)
    total_s = r29 + r54
    bytes_per_s = total_bytes / total_s if total_s else 0.0
    print(
        f"gate_loopback NUMBER rtt_s_29={r29:.4f} rtt_s_54={r54:.4f} "
        f"queries={queries} bytes_per_s={bytes_per_s:.1f} "
        f"shape_bps={SHAPE_BPS}"
    )
    print("journey_txt_query_loopback " + ("PASS" if failures == 0 else "FAIL"))
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
