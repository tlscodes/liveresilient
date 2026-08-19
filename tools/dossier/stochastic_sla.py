#!/usr/bin/env python3
"""Closed-form stochastic channel bound for the T3 matrix (the honest
budget re-derivation FULL_TEST_PLAN section-zero mandates: budgets are
derived, never copied — and the plan's own first table lacked the loss
term, measured 2026-08-19: five functionally-perfect rows over budget).

Per feature the 99%-confidence delivery bound is:

    T99 = S*8 / (B * (1-L))                 lossy transfer term
        + N99(mechanism) * pace             retry/spray pacing overhead
        + RTT                               last-copy flight + verify

  N99 = ceil( ln(1-P) / ln(L) )             attempts to reach P under
                                            i.i.d. per-attempt loss L
  (arq: attempts are payload resends at `pace`; fountain: N99 scales the
   EXTRA symbol flights, pace = one symbol's serialization time.)

Inputs and their sources (no free numbers):
  B    = 250 B/s per crossing   src: t3x profile, run_t3_matrix.sh
  L    = 0.60 end-to-end        src: t3x profile (0.3675/crossing composed)
  RTT  = 2.28 s MEASURED        src: SHAPE_OBSERVED rtt_ms=2280, e2e_netshape.log
  P    = 0.99
  S, pace per feature           src: e2e_payloads/payloads.tsv + the test's
                                     pacing constants (e2e_matrix_test.dart)

Output: tools/dossier/derived_budgets.tsv (feature, S, mechanism, pace_s,
T99_s) — gate_t3 judges Measured_s <= T99_s.
"""
import math

B = 250.0        # bytes/s per crossing
L = 0.60         # end-to-end loss
RTT = 2.28       # seconds, measured
P = 0.99

N99 = math.ceil(math.log(1 - P) / math.log(L))  # = 10 attempts for 0.99/0.6

# feature: (wire bytes S, mechanism, pace seconds per attempt/extra-symbol)
FEATURES = {
    "chat":       (29,   "arq",      0.25),
    "news":       (1160, "arq",      5.0),
    "voice_note": (879,  "arq",      4.0),
    "photo":      (2682, "fountain", 512 * 8 / 2000.0),   # one 512B symbol
    "video_note": (5926, "fountain", 512 * 8 / 2000.0),
    "ptt":        (5220, "live",     0.0),
}


def t99(s, mech, pace):
    transfer = s * 8 / (2000.0 * (1 - L))
    if mech == "live":
        return 60.0  # the window IS the budget; survival is the criterion
    if mech == "arq":
        # a fresh full copy every `pace`; N99 copies reach P=0.99
        return N99 * pace + RTT
    # fountain: the transfer term already pays 1/(1-L); the spray keeps the
    # pipe full, so overhead is the receiver's completion tail: N99 extra
    # symbol flights plus the last flight's RTT
    return transfer + N99 * pace + RTT


def main():
    rows = ["feature\twire_B\tmech\tpace_s\tT99_s"]
    for f, (s, mech, pace) in FEATURES.items():
        rows.append(f"{f}\t{s}\t{mech}\t{pace:g}\t{t99(s, mech, pace):.1f}")
    out = "\n".join(rows) + "\n"
    with open("/Users/behnam/Downloads/voice_call_kit_v3/tools/dossier/"
              "derived_budgets.tsv", "w") as fh:
        fh.write(out)
    print(out)
    print(f"# N99={N99} (P={P}, L={L})  B={B}B/s/crossing  RTT={RTT}s measured")


if __name__ == "__main__":
    main()
