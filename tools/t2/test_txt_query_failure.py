#!/usr/bin/env python3
"""Gate 3 — kill the server mid-session; client declares DOWN inside 60 s. Design §7.3."""

from __future__ import annotations

import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

from txt_query_client import TxtQueryClient, StatusEvent, ValveDown, ValveState  # noqa: E402
from txt_query_server import TxtQueryServer  # noqa: E402

DOMAIN = "example.test"
PORT = 0
failures = 0


def check(name: str, ok: bool, detail: str = "") -> int:
    status = "PASS" if ok else "FAIL"
    extra = f" {detail}" if detail else ""
    print(f"  {status} {name}{extra}")
    return 0 if ok else 1


def main() -> int:
    global failures
    print("gate_failure_detection")
    srv = TxtQueryServer(DOMAIN, host="127.0.0.1", port=PORT, echo=True)
    srv.start()
    time.sleep(0.05)
    seen: list[StatusEvent] = []
    cli = TxtQueryClient(
        DOMAIN,
        server=("127.0.0.1", srv.port),
        timeout_s=3.0,
        fail_threshold=5,
        fail_window_s=60.0,
        on_status=seen.append,
    )
    session, echoed = cli.send(b"warmup")
    failures += check("warmup echo", echoed == b"warmup")
    srv.stop()

    t0 = time.monotonic()
    declared = None
    deadline = t0 + 60.0
    try:
        while time.monotonic() < deadline:
            try:
                cli.poll(session)
            except TimeoutError:
                continue
    except ValveDown as exc:
        declared = exc
    elapsed = time.monotonic() - t0
    cli.close()

    failures += check("declared DOWN", declared is not None)
    failures += check("DOWN within 60s", elapsed <= 60.0, f"{elapsed:.2f}s")
    if declared is not None:
        failures += check("attempts recorded", declared.attempts >= 5, str(declared.attempts))
        failures += check("log has attempts", "attempts=" in declared.event.log_line())
        failures += check("log has replies", "replies=" in declared.event.log_line())
        failures += check("log has up_s", "up_s=" in declared.event.log_line())
    failures += check("callback started UP", bool(seen) and seen[0].state is ValveState.UP)
    failures += check("callback emitted DOWN", any(e.state is ValveState.DOWN for e in seen))

    print(
        f"gate_failure_detection NUMBER down_in_s={elapsed:.2f} "
        f"attempts={getattr(declared, 'attempts', -1)} replies={getattr(declared, 'replies', -1)}"
    )
    print("journey_txt_query_failure " + ("PASS" if failures == 0 else "FAIL"))
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
