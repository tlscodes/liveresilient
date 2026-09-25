# Rewrite or forward? Three names to 8.8.8.8, UDP/53 — 2026-09-24

Standard queries to 8.8.8.8 only; never our zone; no letter, no app nonce; no new Atlas measurement (no Atlas key on the Mac).
Random label: `vcke43498dbe772.example.com` (example.com is IANA's, not ours; the label is unique, so no cache can hold it).

## Atlas public archive — probes 61627 and 1010502 (AS44244 Irancell; 1010502 tagged home/4g/nat)

Every ongoing DNS measurement the two probes are in was listed (61627: 785, 1010502: 433). Exactly one targets 8.8.8.8: msm 43869257, `www.google.com A`, daily. No archived row exists for name 2 or name 3.

```
probe    qname            type  time (UTC)   rcode    answer           TTL  rt ms  verdict
61627    www.google.com   A     09-23 15:26  NOERROR  216.239.38.120   1    42.7   local forgery (SafeSearch VIP, TTL 1)
61627    www.google.com   A     09-24 15:26  NOERROR  216.239.38.120   1    31.4   local forgery
1010502  www.google.com   A     09-23 08:55  NOERROR  216.239.38.120   1    29.3   local forgery
1010502  www.google.com   A     09-24 08:55  NOERROR  216.239.38.120   1    42.3   local forgery
61627    example.com      A     -            -        -                -    -      no row in the public archive
61627    <random> TXT     TXT   -            -        -                -    -      no row in the public archive
1010502  example.com      A     -            -        -                -    -      no row in the public archive
1010502  <random> TXT     TXT   -            -        -                -    -      no row in the public archive
control  NL probe 2047, same msm: 8 Google IPs (142.251.150-157.119), TTL 173-210, rt 25.9-27.6
```

## Globalping — the five IR datacenter probes + one NL control (standard to 8.8.8.8)

www.google.com is the earlier run `2qu1mnvFBqUg9ZIai00021CAi`; names 2 and 3 are one run each: `2H7Dd5lDbzzucOPhm00021CAm`, `2bSD0gOCoA2cMQi1X00021CAm`.

```
probe                      qname                        type  rcode    answer                          TTL  rt ms  verdict
AS202468 AbrArvan (a)      www.google.com               A     NOERROR  216.239.38.120                  418  4      local forgery
AS202468 AbrArvan (b)      www.google.com               A     NOERROR  216.239.38.120                  418  0      local forgery
AS42043  Parsian           www.google.com               A     NOERROR  216.239.38.120                  1    4      local forgery
AS59441  Hostiran          www.google.com               A     NOERROR  216.239.38.120                  418  0      local forgery
AS59580  Batterflyai       www.google.com               A     NOERROR  142.251.152-156.119 (4 shown)   300  207    reached abroad
AS202468 AbrArvan (a)      example.com                  A     NOERROR  188.114.98.0, 188.114.99.0      300  84     reached abroad
AS202468 AbrArvan (b)      example.com                  A     NOERROR  188.114.99.0, 188.114.98.0      300  100    reached abroad
AS42043  Parsian           example.com                  A     NOERROR  188.114.98.0, 188.114.99.0      300  95     reached abroad
AS59441  Hostiran          example.com                  A     NOERROR  188.114.99.0, 188.114.98.0      300  71     reached abroad
AS59580  Batterflyai       example.com                  A     NOERROR  188.114.99.0, 188.114.98.0      300  203    reached abroad
AS60781  LeaseWeb NL ctl   example.com                  A     NOERROR  172.66.147.243, 104.20.23.154   300  13     control
AS202468 AbrArvan (a)      vcke43498dbe772.example.com  TXT   NOERROR  (empty, NODATA)                 -    88     reached abroad
AS202468 AbrArvan (b)      vcke43498dbe772.example.com  TXT   NOERROR  (empty, NODATA)                 -    76     reached abroad
AS42043  Parsian           vcke43498dbe772.example.com  TXT   NOERROR  (empty, NODATA)                 -    91     reached abroad
AS59441  Hostiran          vcke43498dbe772.example.com  TXT   NOERROR  (empty, NODATA)                 -    91     reached abroad
AS59580  Batterflyai       vcke43498dbe772.example.com  TXT   NOERROR  (empty, NODATA)                 -    207    reached abroad
AS60781  LeaseWeb NL ctl   vcke43498dbe772.example.com  TXT   NOERROR  (empty, NODATA)                 -    16     control
```

Verdict rules: local forgery = SafeSearch VIP 216.239.38.120 and/or rt below a real Tehran→abroad round trip (0-4 ms); reached abroad = same answer class as the NL control (example.com: Cloudflare-owned addresses, TTL 300; random TXT: the same NODATA as the NL control) at 71-207 ms; no answer = timeout/none (no such row today).
Limit: 188.114.98.0/99.0 vs the control's 172.66/104.20 are all Cloudflare's; the difference is not explained by this data (a regional pick is the likely reading, not measured).

## What this says, and what it does not

- On the four rewriting datacenter networks, only www.google.com is rewritten; example.com and a never-seen random label under a foreign zone were answered like the NL control, at international round-trip times. The unique label proves an outward lookup happened for it.
- On Irancell consumer (61627, 1010502) the public archive has only www.google.com (forged). Names 2 and 3: no data; no Globalping probe sits on AS44244. Consumer phone UDP/53 beyond the SafeSearch rewrite stays unmeasured.
- Nothing here is about our zone or the Netherlands responder.
