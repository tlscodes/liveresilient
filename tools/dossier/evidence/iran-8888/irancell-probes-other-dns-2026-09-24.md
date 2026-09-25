# Irancell Atlas probes — public DNS measurements other than msm 43869257 — 2026-09-24

Public Atlas archive only (no key on the Mac, nothing created, no letter). Probes: 61627 and 1010502, both AS44244 Irancell; 1010502 is tagged home / 4g / nat.
Listed every ongoing DNS measurement each probe is in: 61627 = 785, 1010502 = 433. Filter: target 8.8.8.8 / 1.1.1.1 / 9.9.9.9, type A or TXT, name not www.google.com. Kept: 2 measurements per probe. None of them targets 8.8.8.8; the rest of the list is mostly root servers and the probe's own resolver.

```
probe    msm        target   name           type  latest (UTC)      rcode    answer (TXT)   TTL  rt ms  source IP        verdict
61627    156155976  1.1.1.1  id.server      TXT   2026-09-24 09:50  NOERROR  "fra03"        0    100.3  2.146.4.147      reached abroad (Cloudflare Frankfurt site)
1010502  156155976  1.1.1.1  id.server      TXT   2026-09-24 13:27  NOERROR  "fra07"        0    570.6  5.119.209.126    reached abroad (Cloudflare Frankfurt site)
61627    156156022  9.9.9.9  hostname.bind  TXT   2026-09-23 17:07  REFUSED  (none)         -    115.0  2.146.4.138      no answer (REFUSED, no site name; who refused is not in the data)
1010502  156156022  9.9.9.9  hostname.bind  TXT   2026-09-24 16:02  NOERROR  "res722.fra"   0    396.9  5.120.84.29      reached abroad (Quad9 Frankfurt node)
```

Verdict rule: "reached abroad" = the answer names the resolver operator's own site (Cloudflare `id.server` → PoP code, Quad9 `hostname.bind` → node name), in Frankfurt, at a round-trip time no local box would need; "local forgery" = the SafeSearch rewrite seen on www.google.com in msm 43869257 (216.239.38.120, TTL 1); "no answer" = no usable answer.

Read together with rewrite-vs-forward-2026-09-24.md: on Irancell, UDP/53 from a 4G home router (1010502) to 1.1.1.1 and 9.9.9.9 today was answered by Cloudflare and Quad9 in Frankfurt, while www.google.com to 8.8.8.8 was rewritten locally. This is a 4G router on the consumer network, not a phone handset, and says nothing about our zone or the Netherlands responder.
