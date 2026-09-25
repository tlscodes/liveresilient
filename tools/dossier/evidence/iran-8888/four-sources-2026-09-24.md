# Four public sources, 2026-09-24 (read-only; one Globalping DNS to 8.8.8.8, never our zone)

```
source            | what was seen                                                                                   | consumer phone UDP/53 answered by Google?
Atlas             | 61627 + 1010502 (AS44244 Irancell; 1010502 tagged home/4g/nat) in public msm 43869257, UDP/53 A www.google.com @8.8.8.8, daily: 4/4 answered, rt 29-42 ms, answer = 216.239.38.120 (forcesafesearch.google.com) TTL 1; NL control probe 2047 same msm = 8 real Google IPs, TTL 173-210 | NO — answered, but rewritten in path (SafeSearch VIP, TTL 1); not proof the query reached Google
Globalping        | id 2qu1mnvFBqUg9ZIai00021CAi, 5 IR datacenter probes, A www.google.com @8.8.8.8 UDP/53: AbrArvan x2 + Hostiran = 216.239.38.120 TTL 418, 0-4 ms; Parsian = 216.239.38.120 TTL 1; Batterflyai AS59580 = 4 real Google IPs TTL 300, 207 ms | NO — datacenters only; 4/5 rewritten, 1/5 (AS59580) reached Google
Cloudflare Radar  | no token on this Mac (CF_TOKEN / CLOUDFLARE_API_TOKEN / CF_API_TOKEN absent)                                                  | BLOCKED
Censored Planet   | data.censoredplanet.org = GraphiQL page, no data links; gs://censoredplanetscanspublic: 401 anonymous list denied; no IR resolver list found | NOT FOUND
```

Raw: Atlas https://atlas.ripe.net/api/v2/measurements/43869257/results/?probe_ids=61627,1010502 (48 h window ending 2026-09-24 15:26 UTC); control probe_ids=2047.
Meaning for the valve: on Irancell 4G, UDP/53 to 8.8.8.8 leaves the house and IS answered — by an in-path rewriter for www.google.com. Whether a query for OUR zone sent to 8.8.8.8 is forwarded or swallowed by the same box is not measured by any of the four sources. No claim about the Netherlands responder.
