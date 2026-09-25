# The window 2026-02-28 .. 2026-06-08: which other public source has rows

The window has 101 calendar days: 2026-02-28 through 2026-06-08, both included.
- Read-only public archives. No measurement was created, and no probe was brought back to life.
- AS44244 / AS197207 in Atlas are already covered in `atlas-gap-2026-02-28-to-06-08.md`: no probe connected. They are not repeated here.
- The country of an ASN comes from RIPEstat rir-stats-country. For Atlas rows, the ASN is the one that announces the row's source IP, not the probe's registration today.

## Answer

| source | status | rows in window | ASNs | abroad or forged |
|---|---|---|---|---|
| OONI dnscheck to 8.8.8.8 / 8.8.4.4 / 1.1.1.1 / 1.0.0.1 / dns.google / cloudflare-dns.com, probe_cc IR | has rows | 8031 listed; 6728 on IR-registered ASNs; 1303 on AS142578 (HK, excluded) | 28 IR-registered ASNs; consumer: AS58224 TCI 3345, AS197207 MCI 650, AS44244 Irancell 203 | Both. A DoH/DoT answer over TLS from Google or Cloudflare means the query reached abroad. The bootstrap lookup of the DoH hostname often came back with a bogon (`dns_bogon_error`), which is a local forgery of that name. Plain UDP/53 is not among these inputs. |
| Atlas msm 156155976, `id.server` TXT @1.1.1.1 over UDP/53, IR probes on ASNs other than 44244 / 197207 | has rows | 1062; 830 from IR-registered origin ASNs | 27 IR-registered ASNs; consumer: only AS58224 TCI, 99 rows | Reached abroad: 787 of 830. The TXT names a Cloudflare site (fra, sof, llk, gyd, dme, cdg, mrs). 16 had no Cloudflare site name (13 of them AS49847). 27 timed out. No forged answer. |
| IODA v2 raw signals, public API, no token (AS44244 / AS197207 / AS58224) | has rows | every day of the window, all three ASNs | 44244, 197207, 58224 | No DNS verdict: these are routing and traffic signals, not DNS answers. |
| Cloudflare Radar | blocked | - | - | There is no token on the Mac, and the public page gives no data for a past range without the API. |
| existing iran-8888 files | has rows, March-April only | see below | L1 per `iran-marapr-layers.md` | Irancell DoH answered by Cloudflare on 03-04. MCI and Irancell OONI uploads arrived abroad within 1 h of the run. Atlas UDP/53 to 8.8.8.8 has no L1 probe. |

Not all four sources are empty, so the one-line "no consumer witness" verdict does not apply. The consumer rows that do exist:
- Irancell (AS44244), OONI: DoH answers from Google and Cloudflare on 02-28 between 00:53 and 04:29 (before 07:24), on 03-04 at 13:21, on 05-07 and 05-08, and on several days from 05-14 to 05-28.
- MCI (AS197207), OONI: DoH to dns.google answered only on 02-28 at 00:18. Every read row after that failed.
- TCI (AS58224), OONI: DoH to dns.google answered on 02-28 (00:38, 03:44), on 03-12 at 15:09, and on 06-07.
- TCI (AS58224), Atlas UDP/53 to 1.1.1.1: answered by Cloudflare sites on 26 days from 2026-05-14 to 06-08.
- Consumer UDP/53 in this window exists only on TCI, from 05-14 on. For Irancell and MCI there is no UDP/53 row in any of these sources.

## OONI detail

Rows listed: 8031. Bodies read:
- a stratified sample of up to 6 per ASN x month, 415 bodies in all;
- every consumer-ASN row before 05-14, plus up to 3 per day after that: 244 bodies.

"answered" means at least one lookup returned A records over the tested resolver. For DoH/DoT that is a TLS-authenticated answer from the named operator.

```
ASN        country  rows  first       last        sampled  answered  main failures in sample
AS58224    IR       3345  2026-02-28  2026-06-08       22         4  generic_timeout_error 16; network_unreachable 5
AS142578   HK       1303  2026-02-28  2026-06-01       30        21  generic_timeout_error 9; host_unreachable 2
AS197207   IR        650  2026-02-28  2026-06-08       18         2  generic_timeout_error 16; bootstrap:dns_bogon_error 12
AS31549    IR        348  2026-02-28  2026-06-08       23         4  generic_timeout_error 19; bootstrap:dns_bogon_error 7
AS52140    IR        310  2026-03-01  2026-06-08       24        21  generic_timeout_error 3; unknown_failure: INTERNAL_ERROR (local): 2
AS47262    IR        288  2026-03-08  2026-05-15       12         0  generic_timeout_error 12
AS44208    IR        216  2026-02-28  2026-06-08       18         3  generic_timeout_error 14; connection_reset 1
AS44244    IR        203  2026-02-28  2026-06-07       22        16  generic_timeout_error 6; bootstrap:dns_bogon_error 5
AS210392   IR        202  2026-05-27  2026-06-07       12         0  generic_timeout_error 12; bootstrap:dns_bogon_error 5
AS51074    IR        181  2026-04-05  2026-06-07       18        18  
AS49100    IR        144  2026-02-28  2026-06-07       18         6  bootstrap:dns_bogon_error 12; generic_timeout_error 12
AS50810    IR        136  2026-02-28  2026-06-07       18         5  generic_timeout_error 13; bootstrap:dns_bogon_error 9
AS202468   IR        132  2026-02-28  2026-06-08       18         1  generic_timeout_error 17; bootstrap:dns_bogon_error 16
AS205647   IR        128  2026-02-28  2026-06-08       16         0  bootstrap:dns_bogon_error 16; generic_timeout_error 16
AS39501    IR         60  2026-02-28  2026-06-08       16         2  bootstrap:dns_bogon_error 14; generic_timeout_error 14
AS61173    IR         60  2026-02-28  2026-06-08       16         0  bootstrap:dns_bogon_error 16; generic_timeout_error 16
AS206065   IR         56  2026-02-28  2026-05-28       12         0  generic_timeout_error 12; bootstrap:dns_bogon_error 9
AS24631    IR         56  2026-02-28  2026-05-24       24        18  generic_timeout_error 6; bootstrap:dns_bogon_error 2
AS49666    IR         54  2026-04-14  2026-05-26       12        10  bootstrap:dns_bogon_error 2; generic_timeout_error 2
AS48715    IR         40  2026-02-28  2026-06-08       12         1  generic_timeout_error 7; bootstrap:dns_bogon_error 4
AS48309    IR         36  2026-05-30  2026-05-31        6         0  generic_timeout_error 6
AS39308    IR         23  2026-03-18  2026-04-09       12         4  generic_timeout_error 8
AS56765    IR         16  2026-05-16  2026-05-17        6         0  bootstrap:dns_bogon_error 6; generic_timeout_error 6
AS16322    IR         12  2026-05-27  2026-05-28        6         0  bootstrap:dns_bogon_error 6; generic_timeout_error 6
AS43754    IR         12  2026-06-07  2026-06-08        6         0  bootstrap:dns_bogon_error 6; generic_timeout_error 6
AS59441    IR          8  2026-06-02  2026-06-06        6         6  
AS200406   IR          4  2026-02-28  2026-02-28        4         2  generic_timeout_error 2; network_unreachable 2
AS48431    IR          4  2026-06-01  2026-06-01        4         0  bootstrap:dns_bogon_error 4; generic_timeout_error 4
AS201150   IR          4  2026-06-05  2026-06-05        4         0  generic_timeout_error 4; network_unreachable 4
IR-registered rows: 6728 of 8031
```

Consumer rows read one by one (the upload-time prefix of `measurement_uid` sits in the same minute as the run):

```
AS44244 Irancell  read 86, answered 49
  answered days: 2026-02-28 (00:53-04:29), 03-04 (13:21, dns.google + cloudflare-dns.com), 05-07, 05-08,
                 05-14, 05-15, 05-16, 05-18, 05-22, 05-27, 05-28
  02-28: dns.google answered; cloudflare-dns.com bogon bootstrap + timeout
AS197207 MCI      read 60, answered 2
  answered: 2026-02-28 00:18 (dns.google); 02-28 05:49 and 05-10 14:31 failed (bogon bootstrap, timeout, network_unreachable)
AS58224 TCI       read 98, answered 8
  answered days: 2026-02-28 (00:38, 03:44), 03-12 15:09 (dns.google), 06-07
```

## Atlas detail (msm 156155976, origin ASN of the row's source IP)

```
origin ASN   note                     rows  abroad  other  timeout  days  first       last        sites
AS12880     DCI (L2, not consumer)    295     291      0        4    99  2026-02-28  2026-06-08  fra:200,sof:34,gyd:24,dme:19,llk:14
AS58224     TCI (L1)                   99      95      0        4    26  2026-05-14  2026-06-08  fra:69,cdg:13,sof:10,llk:2,gyd:1
AS6736                                 47      47      0        0    31  2026-02-28  2026-04-02  fra:47
AS58303                                46      44      0        2    14  2026-05-26  2026-06-08  fra:44
AS39074                                45      40      0        5    15  2026-05-25  2026-06-08  fra:38,mrs:2
AS9147                                 43      43      0        0    43  2026-04-27  2026-06-08  fra:43
AS25184                                40      40      0        0    14  2026-05-26  2026-06-08  fra:40
AS39650                                38      34      3        1    14  2026-05-26  2026-06-08  fra:34
AS43965                                28      28      0        0    14  2026-05-26  2026-06-08  fra:28
AS50558                                14      12      0        2    14  2026-05-26  2026-06-08  fra:12
AS204544                               14      13      0        1    14  2026-05-26  2026-06-08  fra:13
AS61173                                14      12      0        2    14  2026-05-26  2026-06-08  fra:12
AS206065                               13      12      0        1    13  2026-05-27  2026-06-08  fra:12
AS49847                                13       0     13        0    13  2026-05-27  2026-06-08  
AS48289                                13      12      0        1    13  2026-05-27  2026-06-08  fra:12
AS34369                                12      12      0        0    12  2026-05-27  2026-06-08  fra:12
AS48359                                11      11      0        0    11  2026-05-29  2026-06-08  fra:11
AS50810                                10      10      0        0    10  2026-05-27  2026-06-08  fra:10
AS44090                                 8       7      0        1     8  2026-05-27  2026-06-05  fra:7
AS59441                                 6       5      0        1     5  2026-05-26  2026-06-08  fra:5
AS49666                                 6       6      0        0     6  2026-03-04  2026-03-10  fra:6
AS43754                                 5       5      0        0     5  2026-06-04  2026-06-08  sof:5
AS48159                                 4       4      0        0     4  2026-02-28  2026-03-03  fra:4
AS48715                                 2       1      0        1     2  2026-05-26  2026-06-08  fra:1
AS49100                                 2       1      0        1     2  2026-06-07  2026-06-08  fra:1
AS48551                                 1       1      0        0     1  2026-06-08  2026-06-08  fra:1
AS42337                                 1       1      0        0     1  2026-06-08  2026-06-08  fra:1
IR-registered total                      830     787     16       27
excluded: 232 rows from foreign-registered / unknown origin ASNs: AS203273 EE 101, AS57511 AE 48, AS24940 DE 34, AS14593 US 18, AS16276 FR 15, AS51167 DE 9, ASNone None 3, AS12297 AM 2, AS209711 TR 1, AS16628 US 1
```

## IODA detail (days with a nonzero value / days with data, 2026-02-28 .. 06-08)

```
ASN       merit-nt (telescope)  bgp       ping-slash24 (responsive /24)
AS44244   62 / 87               101/101   15 / 101
AS197207  101 / 101             101/101   99 / 101
AS58224   94 / 101              101/101   101 / 101
sample ping-slash24 daily max: AS44244 02-28 21, 03-15 0, 04-15 0, 05-15 0, 06-08 18;
                               AS58224 02-28 6747, 03-15 85, 04-15 93, 05-15 101, 06-08 6717
```

## Existing iran-8888 files that cover part of the window

- `iran-marapr-layers.md` (March-April):
  - AS197207: OONI uploads arrived abroad within 1 h on 32 days, over HTTPS TCP/443.
  - AS44244: the same on 10 days. OONI DoH to Cloudflare answered on 2026-03-04.
  - Atlas UDP/53 for L1: "unknown - no probe".
- `marapr_8888.txt` (March-April): Atlas UDP/53 to 8.8.8.8 was answered on DCI AS12880, IPM AS6736, AS58303, AS9147 and AS39074, with no L1 probe.
- `iran-marapr-2026.md`: IODA / OONI / Atlas day by day for March-April.
- Nothing in the older iran-8888 files covers 2026-05-01 .. 06-08.
