# natprobe — the first public measurement of NAT behavior from inside a network, with no identity data

Three questions decide the architecture of a two-person call that must work with no foreign
server: does the operator's NAT keep one outside port per inside socket (endpoint-independent
mapping), does it let a reply in from an address the socket never sent to (endpoint-independent
filtering), and can two subscribers behind the same NAT reach each other through it (hairpin).
`probe.py` answers them the RFC 4787 / RFC 5780 way against `reflector.py`; `nat_sim.py` is a
userspace NAT with every policy selectable, and `sim_matrix.py` proves the classifier on all of
them before the probe meets a real operator (8 cases, 0 failures on 2026-09-05).

```
python3 tools/natprobe/sim_matrix.py                  # the classifier proof (~2 min)
python3 tools/natprobe/reflector.py --bind 0.0.0.0 --port 3479 --alt-bind <second ip>   # on a domestic host
python3 tools/natprobe/probe.py --reflector <ip>:3479 --alt <second ip> --operator irancell --access mobile \
        --hairpin-room <shared word> --role a        # the other device runs the same with --role b
```

## What is recorded — and what is not

One JSON line per run, nothing else leaves the device:

```
v, probe          schema and probe version
day               the UTC day only (no time)
operator          a label the person picks from a list, or "unknown"
access            mobile | fixed | unknown
local_class       private10 | private172 | private192 | cgnat100.64 | public | other   (the CLASS of the local address)
nat               whether the reflexive address differs from the local one
mapping           eim | adm | apdm | unreachable
filtering         eif | adf | apdf | eif-or-adf (no alternate address) | unreachable
hairpin           yes | no | untested
lifetime_s        >=N bucket of the mapping timeout (optional, --lifetime), or untested
rtt_ms            <50 | 50-200 | 200-1000 | >1000
alt_address_available   whether the reflector had a second IP (filtering is fully decidable only then)
```

Never recorded: any IP address (local or reflexive), ports, device identifiers, exact timestamps,
location. The reflector logs nothing; its mailbox holds a reflexive address in memory for
120 s under a random room the two devices chose, then forgets it. The probe traffic is a few
dozen small UDP datagrams to one host — the same shape every game and VoIP app produces at
start. Publish only counts per (operator, access) cell, and only cells with at least 10 samples.

## Why these three, and what each verdict decides

| verdict                     | what it means for the app                                                   |
|-----------------------------|------------------------------------------------------------------------------|
| mapping = eim               | one reflexive address discovery per socket is enough; punching works        |
| mapping = adm / apdm        | the peer must aim at a mapping created toward IT; a relay is the fallback   |
| filtering = eif             | the peer can send first; a host behind this NAT can serve friends briefly   |
| filtering = adf / apdf      | both sides must punch (the ICE way); nobody behind it can host              |
| hairpin = yes               | two subscribers of the same operator can talk directly via their public side|
| hairpin = no                | same-operator peers need a host outside that NAT                            |
| lifetime_s                  | the keepalive interval a phone-as-host must pay (bytes per hour)            |

## How many samples

A proportion with a 95 % interval of ±10 points needs about 96 samples per cell; ±15 points
about 43. To tell "mostly endpoint-independent" from "mostly symmetric" for one operator,
30 samples on distinct days and places is the first honest number; a cell under 10 is not
published. Mobile NATs differ per region and gateway, so spread samples across provinces.
Target: 5 major operators × 2 access types × ≥30 = 300 samples for a first public table.

## Field limits (say them, do not hide them)

- Filtering is fully decidable only with an alternate reflector ADDRESS; with one host the record
  says `eif-or-adf` and is still useful for mapping and hairpin.
- The probe measures the path to the reflector's host; a carrier that treats domestic hosts
  differently from foreign ones must be probed against a domestic reflector.
- The FaceTime/Android app port of this probe is the next step; this Python form is for laptops
  on the same lines and for proving the classifier.
