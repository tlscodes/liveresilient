# Where volunteer phones in Iran got through: OONI web_connectivity, 2026-03-01 .. 2026-05-25

Valid bodies read: 10521 of 10521 listed web_connectivity rows for AS44244 (Irancell) and AS197207 (MCI) in the window. June is not included. Rows OONI answered with 429 or an empty body are not counted as anything; they are simply not read yet.

Status comes from each body's test_keys:
- `ok` = accessible true and blocking false.
- `anomaly` = blocking names a mechanism: dns, tcp_ip, http-failure or http-diff.
- `failed` = the test reached no verdict: both are null.

Destination = the host of the tested URL. Probe ASN = the network OONI saw the phone on. resolver_asn = the network of the resolver's egress as seen from outside.

## Coverage (valid bodies / listed)

```
AS197207  2026-03     932 / 932     ok   551  anomaly   358  failed    23
AS197207  2026-04    3269 / 3269    ok  1411  anomaly  1674  failed   184
AS197207  2026-05    4826 / 4826    ok  1800  anomaly  2707  failed   319
AS44244   2026-03     382 / 382     ok   269  anomaly   101  failed    12
AS44244   2026-04     316 / 316     ok   184  anomaly   125  failed     7
AS44244   2026-05     796 / 796     ok   361  anomaly   415  failed    20
```

## Totals by probe ASN

```
AS197207  ok   3762  anomaly   4739  failed    526
AS44244   ok    814  anomaly    641  failed     39
all       ok   4576  anomaly   5380  failed    565
```

## 20 most frequent destinations that were `ok`

```
destination                            count  total     ok  anom  fail  probe ASN              resolver_asn (top 3)
www.youtube.com                           64    143     64    78     1  197207:119 44244:24    AS197207:41 AS49666:30 AS13335:26
chehre.app                                22     22     22     0     0  197207:13 44244:9      AS49666:8 AS197207:6 AS13335:4
www.facebook.com                          20    180     20   160     0  197207:144 44244:36    AS197207:51 AS49666:40 AS13335:32
scontent-frt3-2.cdninstagram.com          20     27     20     7     0  197207:22 44244:5      AS197207:12 AS49666:5 AS15169:4
azadlo.ir                                 19     21     19     0     2  197207:16 44244:5      AS197207:7 AS49666:4 AS15169:4
www.instagram.com                         17    155     17   137     1  197207:130 44244:25    AS197207:42 AS49666:33 AS13335:28
gettr.com                                 17     18     17     1     0  197207:13 44244:5      AS197207:7 AS49666:4 AS13335:3
locals.com                                17     18     17     0     1  197207:13 44244:5      AS197207:6 AS49666:4 AS13335:3
fa.kurddestiny.com                        17     17     17     0     0  197207:15 44244:2      AS13335:4 AS0:4 AS197207:4
s.pinimg.com                              16     16     16     0     0  197207:11 44244:5      AS197207:5 AS49666:4 AS13335:3
plus.im                                   16     16     16     0     0  197207:11 44244:5      AS197207:5 AS49666:4 AS13335:3
gab.com                                   16     18     16     1     1  197207:13 44244:5      AS197207:7 AS49666:4 AS13335:3
www.ning.com                              16     16     16     0     0  197207:11 44244:5      AS49666:4 AS15169:4 AS197207:4
www.yelp.com                              16     17     16     1     0  197207:12 44244:5      AS197207:7 AS49666:4 AS13335:3
bricspress.live                           15     17     15     1     1  197207:13 44244:4      AS197207:6 AS15169:4 AS49666:3
twitter.com                               15    146     15   131     0  197207:121 44244:25    AS197207:41 AS49666:31 AS13335:27
www.wechat.com                            15     16     15     1     0  197207:11 44244:5      AS197207:5 AS49666:4 AS13335:3
mastodon.sdf.org                          15     17     15     1     1  197207:12 44244:5      AS197207:5 AS49666:4 AS13335:3
mastodon.xyz                              15     17     15     1     1  197207:12 44244:5      AS197207:5 AS49666:4 AS13335:3
patogh.me                                 15     16     15     1     0  197207:11 44244:5      AS197207:5 AS49666:4 AS13335:3
```

## 20 most frequent destinations with an `anomaly` (blocked; mechanism shown)

```
destination                            count  total     ok  anom  fail  probe ASN              resolver_asn (top 3)
www.facebook.com                         160    180     20   160     0  197207:144 44244:36    AS197207:51 AS49666:40 AS13335:32 dns:90,http-failure:70
www.instagram.com                        137    155     17   137     1  197207:130 44244:25    AS197207:42 AS49666:33 AS13335:28 dns:72,http-failure:65
twitter.com                              131    146     15   131     0  197207:121 44244:25    AS197207:41 AS49666:31 AS13335:27 dns:71,http-failure:58
www.youtube.com                           78    143     64    78     1  197207:119 44244:24    AS197207:41 AS49666:30 AS13335:26 dns:74,tcp_ip:3
6rang.org                                 25     30      5    25     0  197207:20 44244:10     AS197207:11 AS49666:10 AS13335:6 dns:12,http-diff:6
alhayat.com                               22     22      0    22     0  197207:17 44244:5      AS197207:11 AS49666:5 AS13335:4 dns:22
fa.rezapahlavi.org                        19     19      0    19     0  197207:17 44244:2      AS197207:6 AS13335:4 AS0:4 dns:19
www.tiktok.com                            18     21      3    18     0  197207:15 44244:6      AS197207:8 AS49666:5 AS13335:4 dns:10,http-failure:8
edaalat.org                               18     18      0    18     0  197207:14 44244:4      AS13335:4 AS197207:4 AS49666:3 dns:11,http-failure:7
badoo.com                                 17     19      2    17     0  197207:14 44244:5      AS197207:6 AS49666:5 AS13335:3 dns:9,http-failure:8
x.com                                     17     22      5    17     0  197207:16 44244:6      AS197207:9 AS49666:5 AS13335:4 dns:16,http-failure:1
i.pinimg.com                              17     19      1    17     1  197207:14 44244:5      AS197207:7 AS49666:4 AS13335:3 dns:10,http-failure:7
www.pinterest.co.uk                       16     17      1    16     0  197207:12 44244:5      AS197207:6 AS49666:4 AS13335:3 dns:9,http-failure:7
www.joinclubhouse.com                     16     17      1    16     0  197207:12 44244:5      AS197207:5 AS49666:4 AS15169:4 dns:9,http-failure:6
www.douyin.com                            16     18      1    16     1  197207:13 44244:5      AS197207:6 AS49666:4 AS15169:4 dns:10,http-failure:6
www.clubhouse.com                         16     17      1    16     0  197207:12 44244:5      AS197207:6 AS49666:4 AS13335:3 dns:9,http-failure:7
coocheh.com                               16     17      0    16     1  197207:12 44244:5      AS197207:5 AS49666:4 AS15169:4 dns:16
discover.hubpages.com                     16     17      1    16     0  197207:12 44244:5      AS197207:6 AS49666:4 AS13335:3 http-failure:8,dns:8
fbcdn.net                                 16     18      2    16     0  197207:13 44244:5      AS197207:7 AS49666:4 AS13335:3 http-failure:10,dns:6
groups.google.com                         16     18      1    16     1  197207:13 44244:5      AS197207:6 AS49666:4 AS13335:3 http-failure:9,dns:7
```

## 20 most frequent destinations that `failed` (no verdict)

```
destination                            count  total     ok  anom  fail  probe ASN              resolver_asn (top 3)
elpha.com                                 16     17      0     1    16  197207:12 44244:5      AS197207:6 AS49666:4 AS13335:3 dns:1
facenama.com                              13     17      2     2    13  197207:12 44244:5      AS197207:6 AS49666:4 AS13335:3 dns:2
globalvoices.org                          12     13      0     1    12  197207:11 44244:2      AS13335:3 AS197207:3 AS49666:2 dns:1
myspace.com                               11     18      0     7    11  197207:12 44244:6      AS49666:5 AS197207:5 AS13335:3 dns:7
advox.globalvoices.org                    11     14      0     3    11  197207:9 44244:5       AS49666:5 AS197207:5 AS13335:3 dns:2,tcp_ip:1
alaflaaj.com                              11     14      2     1    11  197207:9 44244:5       AS49666:5 AS197207:4 AS13335:3 tcp_ip:1
ghanoondaily.ir                            8     13      0     5     8  197207:11 44244:2      AS13335:3 AS197207:3 AS49666:2 dns:3,tcp_ip:2
i2p2.de                                    8     14      0     6     8  197207:12 44244:2      AS13335:4 AS197207:4 AS49666:2 dns:6
mask-h2.icloud.com                         8      8      0     0     8  197207:7 44244:1       AS49666:4 AS13335:3 AS197207:1
triller.co                                 7     16      2     7     7  197207:11 44244:5      AS197207:5 AS49666:4 AS13335:3 tcp_ip:4,dns:3
lgbtvacationplanners.com                   7      7      0     0     7  197207:6 44244:1       AS49666:3 AS13335:3 AS197207:1
gaymenshealth.org                          6     15      4     5     6  197207:13 44244:2      AS197207:4 AS13335:3 AS49666:2 dns:3,http-failure:1
grindr.mobi                                6     15      7     2     6  197207:13 44244:2      AS197207:5 AS13335:3 AS49666:2 dns:2
proxy.i2phides.me                          6      7      0     1     6  197207:6 44244:1       AS49666:3 AS13335:2 AS197207:1 dns:1
webneveshteha.com                          6     13      2     5     6  197207:11 44244:2      AS49666:4 AS0:3 AS13335:2 dns:5
hivsti.com                                 6      7      0     1     6  197207:7               AS13335:4 AS15169:1 AS197207:1 dns:1
icq.com                                    6      8      0     2     6  197207:8               AS13335:5 AS15169:2 AS197207:1 http-failure:2
www.clubhouseapi.com                       5     16      3     8     5  197207:11 44244:5      AS197207:5 AS49666:4 AS13335:3 http-failure:5,dns:3
www.viber.com                              5     16     10     1     5  197207:11 44244:5      AS197207:5 AS49666:4 AS13335:3 tcp_ip:1
www.dit-inc.us                             5      7      0     2     5  197207:7               AS13335:2 AS15169:2 AS49666:1 http-failure:2
```

## 8.8.8.8 and 1.1.1.1, counted separately

```
in the tested URL (input):   1.1.1.1 AS197207 anomaly:11, 1.1.1.1 AS197207 ok:1, 1.1.1.1 AS44244 anomaly:4, 1.1.1.1 AS44244 ok:1, 8.8.8.8 AS197207 ok:2
as resolver_ip:              none
```

Distinct destinations: 1492. Source: api.ooni.io measurement bodies, read one by one; the list API's own anomaly flags are not used.
