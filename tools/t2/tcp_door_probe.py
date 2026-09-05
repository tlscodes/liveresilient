#!/usr/bin/env python3
"""Verify the whitelist filter from the Mac side with TCP, not ICMP.

The whitelist profile drops ICMP by design, so journey_run.sh cannot use the
ping check every other profile uses. This probe replaces it and asserts BOTH
directions of the claim, because a check that only proves "the allowed port
works" cannot tell a whitelist from a wide-open network.

What the two connects mean on this rig (Mac -> phone over bridge100, with
tools/t2/net_shape.sh whitelist loaded):

  allowed port  the SYN matches `pass out ... port { <allowed tcp> } keep
                state`, so it crosses. The phone runs no listener on that
                port, so it answers with a reset, and the reset rides the
                state back. A DEFINITE answer (refused, or connected if
                something does listen) therefore proves the allowed path
                carries traffic in both directions under the filter.
  blocked port  the SYN matches no pass rule; the phone's answer is swallowed
                by `block drop in quick ... from <peer> to any`. So the
                connect must produce NO answer at all: a timeout.

Hence: allowed = refused|open, blocked = timeout. Any other combination means
the filter is not doing what the row will claim, and the caller must stop.

  python3 tools/t2/tcp_door_probe.py <host> <allowed_port> <blocked_port> [timeout_s]

Prints one line:
  allowed=<state>,<ms> blocked=<state>,<ms> verdict=<pass|fail>
Exit 0 on pass, 1 on fail, 2 on a bad argument.
"""
import socket
import sys
import time

DEFINITE = ('open', 'refused')


def probe(host: str, port: int, timeout: float) -> tuple[str, int]:
    """Connect once and name what happened, with the elapsed milliseconds."""
    started = time.monotonic()
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.settimeout(timeout)
    try:
        sock.connect((host, port))
        state = 'open'
    except socket.timeout:
        state = 'timeout'
    except ConnectionRefusedError:
        state = 'refused'
    except OSError as error:
        # A reset arriving as ECONNRESET, and an unreachable host, are both
        # definite answers from the network; keep the errno so the caller can
        # read what the phone said.
        state = 'refused' if error.errno in (54, 104) else 'error:%s' % error.errno
    finally:
        sock.close()
    return state, int((time.monotonic() - started) * 1000)


def verdict(allowed_state: str, blocked_state: str) -> str:
    """The single place the two observations become pass or fail."""
    if allowed_state in DEFINITE and blocked_state == 'timeout':
        return 'pass'
    return 'fail'


def parse_port(value: str) -> int:
    port = int(value)
    if not 1 <= port <= 65535:
        raise ValueError('port out of range: %s' % value)
    return port


def main(argv: list[str]) -> int:
    if len(argv) not in (4, 5):
        print(__doc__.strip().splitlines()[-4].strip(), file=sys.stderr)
        return 2
    try:
        host = argv[1]
        allowed_port = parse_port(argv[2])
        blocked_port = parse_port(argv[3])
        timeout = float(argv[4]) if len(argv) == 5 else 3.0
    except ValueError as error:
        print('tcp_door_probe: %s' % error, file=sys.stderr)
        return 2
    allowed_state, allowed_ms = probe(host, allowed_port, timeout)
    blocked_state, blocked_ms = probe(host, blocked_port, timeout)
    result = verdict(allowed_state, blocked_state)
    print(
        'allowed=%s,%dms blocked=%s,%dms verdict=%s'
        % (allowed_state, allowed_ms, blocked_state, blocked_ms, result)
    )
    return 0 if result == 'pass' else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv))
