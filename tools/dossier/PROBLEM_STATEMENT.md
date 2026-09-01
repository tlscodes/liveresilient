# Problem statement

*Every figure on this page is attributed to the organisation that published it.
Where sources disagree, the disagreement is shown rather than resolved in our
favour — a reviewer will check, and a number we cannot defend costs more than
it buys.*

## The condition this project is built for

Between **8 January and 26 May 2026**, Iran experienced a nationwide internet
blackout lasting **four months and eighteen days**. Network measurement
organisations recorded it as the **longest nation-scale internet shutdown on
record in any country**; NetBlocks reported connectivity flatlining at about
1% of ordinary levels, and had logged **1,056 hours** of shutdown by its
forty-fifth day. More than **90 million people** were affected. (NetBlocks;
Access Now / #KeepItOn.)

Casualty figures from that period are contested and this document does not
adopt one. Statements attributed to the US administration cited 42,000, then
60,000, then 100,000 protesters killed; Iranian authorities stated 3,117
including security personnel; independent tallies reported by news
organisations reached about 5,002. Reporting notes that the basis for the
higher figures was not made clear. We cite this range only to show that the
period is disputed and heavily documented — the engineering case rests on the
measured connectivity data, not on a casualty number.

## Why existing tools fail in that condition

A shutdown is rarely total for everyone or forever. What people are left with
is a link that technically carries packets but cannot carry a conversation:
a few kilobits per second, heavy loss, and seconds of latency. Mainstream
messengers are not built for that floor. They assume a working congestion
control loop and enough bandwidth to complete a media upload; under 60%
random loss the transport itself collapses — measured on our rig at about two
packets per second — long before the application layer gets a chance.

The result is the failure mode that matters: a person can see the connection
icon, and still cannot send a voice message, a photograph, or reach a call.

## What this project does about it

It removes both assumptions.

- **The transport does not depend on a loss-reactive control loop.** Bulk
  content is carried as rateless coded symbols over plain UDP, so loss costs
  proportional extra symbols instead of a round trip. Measured: a 4 MiB object
  delivered over a 60%-loss link at 2.54× symbol overhead, against a
  theoretical floor of 2.5×.
- **The application layer is sized for the floor.** Every feature has a byte
  budget proven by a gate: a message at 29 bytes, a news page at 1,160 bytes,
  a photograph at 2,682 bytes, ten seconds of speech at 879 bytes, a five
  second video note at 5,926 bytes, and a minute of push-to-talk at 5,220
  bytes.
- **The claims are reproducible.** Twenty-four transport rows and six codec
  gates pass with their logs; the six end-to-end features were then measured
  on a physical iPhone over a shaped link, each inside a budget derived from
  the link physics.

At 2 kbit/s, those numbers mean a message arrives in about two and a half
seconds and a photograph in about twenty-three — on a link where the
alternatives deliver nothing at all.

## Sources

- 2026 internet blackout in Iran — https://en.wikipedia.org/wiki/2026_Internet_blackout_in_Iran
- NetBlocks: longest nationwide shutdown on record — https://english.alarabiya.net/News/middle-east/2026/04/05/iran-internet-blackout-is-longest-nationwide-shutdown-on-record-netblocks
- NetBlocks: 1,056 hours — https://iranwire.com/en/news/151163-netblocks-1056-hours-of-internet-shutdown-in-iran-officials-and-influencers-dominate/
- Reporting on contested casualty figures — https://www.aljazeera.com/video/newsfeed/2026/1/13/trump-says-iran-protest-death-toll-too-high
- Independent tally reported at 5,002 — https://www.euronews.com/embed/2864503

Project measurements: `tools/phase5/h3_results.tsv`, `tools/t2/h2_results.tsv`,
`tools/dossier/e2e_ios_results.tsv`, with the logs that produced them under
`tools/suite-logs/` and `tools/dossier/logs/`.
