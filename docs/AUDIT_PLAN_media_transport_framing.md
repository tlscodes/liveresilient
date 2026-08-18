# Audit Plan — Media Transport Framing (4 Sections)

هر بخش یک پرامپت مستقل ممیزی است؛ بخش ۱ همان چک فریم‌بندی/پدینگ/بازسازی/آنتروپی است که با کد واقعی اجرا و نمره‌گذاری شد.

---

## بخش ۱ — Protocol Framing, MTU Block Alignment, and Buffer Overflow Safety

```
Act as a Senior Network & Transport Protocol Auditor. I am conducting an RFC
Conformance and Memory Safety Audit on my application's media transport
framing layer (RFC 9113, RFC 8831, and RFC 3711).

Please evaluate my code implementation against a 0–100% Readiness &
Compliance Score for:
"Protocol Framing, MTU Block Alignment, and Buffer Overflow Safety"

Please evaluate the code based on the following 4 sub-weighted criteria
(25% each):

1. Standard L7 Protocol Framing (25%):
   - Are media payloads encapsulated strictly within standard HTTP/2 DATA
     frames (RFC 9113) or SCTP DataChannels (RFC 8831)?
   - Are frame headers strictly compliant with protocol state
     specifications (including initial handshake frames — HEADERS/SETTINGS
     for HTTP/2, DCEP DATA_CHANNEL_OPEN for SCTP) to prevent parsing
     anomalies?

2. Dynamic MTU Block Padding & Bounds Checking (25%):
   - Is dynamic block alignment correctly applied across variable
     boundaries (e.g., 16-byte boundaries per RFC 3711)?
   - Is the padding-length field's own storage width validated against its
     own maximum possible value? Specifically: if padLength is stored in a
     single byte, is (maxRandomPad + blockSize) provably bounded below 256
     at every call site — including realistic full-MTU block sizes
     (1400–1500 bytes) — or can it silently wrap via integer truncation?

3. Bit-Exact Reconstruction & Payload Integrity (25%):
   - Does the unpadding logic guarantee 100% bit-exact restoration of the
     underlying rateless payload without memory corruption or array
     index out-of-bounds errors?
   - If a lower layer (e.g., a CRC) can mask a padding-layer corruption as
     a dropped/rejected datagram instead of surfacing it, say so explicitly
     — silent packet loss is still a compliance defect, not a pass.

4. Framing Overhead & Padding Entropy Distribution (25%):
   - Is padding content filled securely with non-zero entropy bytes, and
     does the padding size distribution avoid rigid quantization artifacts
     (e.g., every wire length landing on an exact multiple of blockSize)?

Here is my current implementation (file paths, read each in full):
- packages/adaptive_transport/lib/src/frame_encapsulator.dart
- packages/adaptive_transport/lib/src/micro_datagram_lane.dart
- packages/connection_orchestrator/lib/src/media_carriage.dart
- packages/connection_orchestrator/lib/src/rateless_stream.dart
  (downstream CRC-8 layer — needed to judge whether a padding bug becomes
  silent corruption or just a rejected/dropped datagram)

Instructions:
- Provide a detailed breakdown for each of the 4 criteria.
- Assign a percentage score for each sub-item and an overall readiness
  score (0–100%).
- Identify any RFC non-compliance issues, integer overflow risks, or
  edge-case failures, each with the exact file:line and the input that
  triggers it.
- Maintain a strict, standards-based protocol audit perspective.
```

**نتیجه‌ی اجراشده (2026-07-27، امتیاز 58/100):**

| معیار | امتیاز | یافته‌ی اصلی |
|---|---|---|
| ۱. فریم‌بندی استاندارد | 70/100 | هدرها بایت‌دقیق‌اند؛ HEADERS/SETTINGS و DCEP OPEN هرگز فرستاده نمی‌شوند |
| ۲. پدینگ MTU + Bounds | 45/100 | overflow واقعی در `micro_datagram_lane.dart:32` وقتی `mtuBlockSize > 224` |
| ۳. بازسازی بیت‌به‌بیت | 55/100 | همان باگ را می‌شکند؛ CRC-8 پایین‌دستی آن را به‌جای فساد بی‌صدا، افت بسته می‌کند |
| ۴. آنتروپی/الگو | 60/100 | نویزِ بایت درست است؛ طولِ کوانتیزه‌ی دقیق روی مضرب blockSize خودش امضاست |

---

## بخش ۲ — Record-Layer Cryptography, Key Schedule, and Replay Defence

```
Act as a Senior Applied Cryptography Auditor. I am conducting a record-layer
audit on my application's secure media lane (RFC 5869 HKDF, RFC 5802 SCRAM,
RFC 3711 SRTP replay handling, and AEAD nonce-reuse discipline).

Please evaluate my code implementation against a 0–100% Readiness &
Compliance Score for:
"Record-Layer Cryptography, Key Schedule, and Replay Defence"

Please evaluate the code based on the following 4 sub-weighted criteria
(25% each):

1. Key Derivation and Separation (25%):
   - Is every key derived through HKDF with a distinct, non-overlapping
     info/label per direction and per purpose (send vs receive, media vs
     control), so that no two roles can ever derive the same key?
   - Is the salt/IKM path free of low-entropy inputs, and is the exporter
     binding tied to the authenticated session rather than to a value an
     attacker can choose?

2. AEAD Nonce Discipline (25%):
   - Is the nonce constructed so that a repeat is structurally impossible
     for a given key — sequence-derived, never random-per-record, never
     reset on reconnect while the key is retained?
   - What happens at sequence-number exhaustion: does the lane refuse to
     send (correct), wrap (catastrophic), or silently continue (worse)?
     Name the exact file:line of the exhaustion branch, or state that no
     such branch exists.

3. Replay and Reorder Window (25%):
   - Is the anti-replay window a bitmap of stated width, and is the
     accept/reject decision made BEFORE the payload reaches any consumer?
   - Are the three boundaries tested: a duplicate inside the window, a
     packet older than the window's left edge, and a jump far past the
     right edge? Reordering on a lossy path is the normal case here, so a
     window that is correct but too narrow is a functional defect, not a
     tuning preference.

4. Authentication Binding and Downgrade Resistance (25%):
   - Is the SCRAM/exporter authentication bound to the same session the
     media keys come from, so that a successful auth on one channel cannot
     be replayed to authorise another?
   - Can any negotiated parameter downgrade the lane to a weaker or null
     cipher, and is that path refused with a typed error rather than a
     silent fallback?

Here is my current implementation (file paths, read each in full):
- packages/adaptive_transport/lib/src/hkdf_key_schedule.dart
- packages/adaptive_transport/lib/src/anti_replay_window.dart
- packages/adaptive_transport/lib/src/scram_exporter_auth.dart
- packages/adaptive_transport/lib/src/secure_transport_session.dart
- packages/connection_orchestrator/lib/src/secure_media_lane.dart

Instructions:
- Provide a detailed breakdown for each of the 4 criteria.
- Assign a percentage score for each sub-item and an overall readiness
  score (0–100%).
- Identify any nonce-reuse risk, key-separation collision, or window
  off-by-one, each with the exact file:line and the input that triggers it.
- Treat "no test covers this" as a finding in its own right, distinct from
  "the code is wrong".
```

**وضعیت:** نوشته شد ۲۰۲۶-۰۷-۳۱ · هنوز اجرا نشده. هیچ امتیازی برای این بخش
ادعا نمی‌شود تا وقتی که روی کد واقعی اجرا شود و جدولِ نتیجه مثل بخش ۱ پر شود.

| معیار | امتیاز | یافته‌ی اصلی |
|---|---|---|
| ۱. اشتقاق و تفکیک کلید | — | اجرا نشده |
| ۲. انضباط nonce | — | اجرا نشده |
| ۳. پنجره‌ی ضد-بازپخش | — | اجرا نشده |
| ۴. اتصال احراز و ضد-تنزل | — | اجرا نشده |

---

## بخش ۳ — Loss Recovery, Rateless Coding, and Reassembly Safety

```
Act as a Senior Coding-Theory and Systems Auditor. I am conducting a
correctness and resource-safety audit on my application's loss-recovery
layer (rateless/fountain coding over GF(256), chunked transfer, and
reassembly).

Please evaluate my code implementation against a 0–100% Readiness &
Compliance Score for:
"Loss Recovery, Rateless Coding, and Reassembly Safety"

Please evaluate the code based on the following 4 sub-weighted criteria
(25% each):

1. Decoder Correctness Under Real Loss (25%):
   - Does the decoder recover the exact source block once it holds enough
     independent coded symbols, and is independence actually checked rather
     than assumed from the count?
   - Is the behaviour under a bursty (Gilbert–Elliott) loss pattern tested,
     not only under uniform random loss? Burst loss is the field condition;
     uniform loss is the easy case.

2. Bounded Resources on a Hostile Input (25%):
   - Are chunk count, pending-block count, and per-chunk byte size all
     capped, and is every cap enforced before allocation rather than after?
   - Can a peer that never completes a block hold memory indefinitely, and
     is there an eviction path with a stated policy?

3. Conflicting and Malformed Symbols (25%):
   - If two symbols claim the same index with different contents, is the
     conflict rejected with a typed error rather than last-write-wins?
   - Are truncated headers, non-minimal length encodings, and
     out-of-range coefficients each rejected as distinct typed errors —
     and does a test exist for EACH variant, or are some variants
     unreachable dead code that should be deleted?

4. Interaction With the Layer Below (25%):
   - The datagram layer carries a CRC-8. State explicitly whether a
     corruption introduced at the coding layer can be masked by that CRC as
     an ordinary dropped datagram — a defect that presents as loss is still
     a defect.
   - Does the overhead of coding stay within the stated budget at the
     smallest MTU the product supports, or does redundancy silently exceed
     the payload it protects?

Here is my current implementation (file paths, read each in full):
- packages/connection_orchestrator/lib/src/rateless_stream.dart
- packages/connection_orchestrator/lib/src/gf256_rlnc_stream.dart
- packages/connection_orchestrator/lib/src/chunked_transfer.dart
- packages/connection_orchestrator/lib/src/gilbert_elliott_loss.dart
- packages/connection_orchestrator/lib/src/media_queue.dart

Instructions:
- Provide a detailed breakdown for each of the 4 criteria.
- Assign a percentage score for each sub-item and an overall readiness
  score (0–100%).
- For every unbounded allocation or missing typed error, give the exact
  file:line and the smallest input that reaches it.
- A test that compares a value to itself does not count as coverage; say so
  where you find one.
```

**وضعیت:** نوشته شد ۲۰۲۶-۰۷-۳۱ · هنوز اجرا نشده.

| معیار | امتیاز | یافته‌ی اصلی |
|---|---|---|
| ۱. صحت رمزگشا زیر افت | — | اجرا نشده |
| ۲. منابع کران‌دار | — | اجرا نشده |
| ۳. نمادهای متعارض و بدشکل | — | اجرا نشده |
| ۴. تعامل با لایه‌ی پایین | — | اجرا نشده |

---

## بخش ۴ — Observable Traffic Pattern, Lane Selection, and Cost Bounds

```
Act as a Senior Traffic-Analysis and Systems Auditor. I am conducting an
observability and cost audit on my application's lane-selection and
long-poll layer. Scope note, and it is a hard one: this product does NOT
attempt to disguise its traffic as another protocol, and CI
(tool/architecture_guard.dart) fails the build on any such component. So do
not recommend protocol mimicry, domain fronting, or transport obfuscation.
The question is what an observer can conclude from a standards-compliant
flow, and which of those conclusions the product currently states honestly.

Please evaluate my code implementation against a 0–100% Readiness &
Compliance Score for:
"Observable Traffic Pattern, Lane Selection, and Cost Bounds"

Please evaluate the code based on the following 4 sub-weighted criteria
(25% each):

1. Cadence Fingerprint (25%):
   - The HTTP long-poll lane holds for a fixed 25 s. Quantify what a
     passive observer learns from a fixed inter-request interval versus a
     randomised one, and state whether the code randomises it today
     (file:line) or not.
   - Is any size lattice applied to outgoing frames, and does that lattice
     itself become a signature (every length an exact multiple of the block
     size is its own fingerprint)?

2. Measurability of the Claim (25%):
   - Is there ANY test in the repository that scores how distinguishable
     this traffic is — a divergence metric, a classifier, anything numeric?
     If not, say plainly that the central anti-classification claim is
     unmeasured, and that no score above 0 can be awarded for it.
   - If a metric were added, name the exact interface it needs from this
     code: per-packet size, direction, and inter-arrival delta.

3. Lane Selection Under Failure (25%):
   - Is lane ranking a function of measured health (EWMA availability, RTT,
     breaker state) rather than static preference, and does a tripped
     breaker actually stop selection?
   - On failover, does the switch itself create a distinguishable
     signature — a burst of retries, a sudden cadence change — and is that
     bounded?

4. Cost and Capacity Bounds (25%):
   - At 288 requests per hour per call, state the requests-per-day ceiling
     the deployed relay's free tier allows, and whether the code enforces
     any ceiling of its own or relies on the provider cutting it off.
   - Is there a budget or quota guard in the repository, or is the only
     protection an invoice? Name the file, or state that none exists.

Here is my current implementation (file paths, read each in full):
- packages/adaptive_transport/lib/src/resilient/http_long_poll_lane.dart
- packages/adaptive_transport/lib/src/resilient/resilient_fallback_transport_chain.dart
- packages/adaptive_transport/lib/src/resilient/poisson_pacer.dart
- packages/adaptive_transport/lib/src/path_selector.dart
- packages/adaptive_transport/lib/src/circuit_breaker.dart
- tools/cloudflare_relay_worker/src/worker.js

Instructions:
- Provide a detailed breakdown for each of the 4 criteria.
- Assign a percentage score for each sub-item and an overall readiness
  score (0–100%).
- Where a claim is unmeasured, score it as unmeasured and say what
  measurement would settle it — do not award partial credit for intent.
- Recommendations must stay inside the standards-only constraint above.
```

**وضعیت:** نوشته شد ۲۰۲۶-۰۷-۳۱ · هنوز اجرا نشده. این بخش مستقیماً به دو
شکافِ باز گره خورده است: نبودِ سنجه‌ی تفکیک‌ناپذیری و نبودِ شکل‌دهیِ
اندازه/زمان.

| معیار | امتیاز | یافته‌ی اصلی |
|---|---|---|
| ۱. اثرِ انگشتِ آهنگ | — | اجرا نشده |
| ۲. سنجش‌پذیریِ ادعا | — | اجرا نشده |
| ۳. انتخاب مسیر زیر شکست | — | اجرا نشده |
| ۴. کران هزینه و ظرفیت | — | اجرا نشده |

---

## صداقت درباره‌ی این سند

بخش ۱ روی کد واقعی اجرا و نمره‌گذاری شد (۲۰۲۶-۰۷-۲۷، ۵۸ از ۱۰۰).
بخش‌های ۲ و ۳ و ۴ در ۲۰۲۶-۰۷-۳۱ نوشته شدند و هنوز اجرا نشده‌اند؛ جدولِ
هرکدام عمداً خالی است تا کسی نتواند آن را با نتیجه اشتباه بگیرد. مسیرهای
فایل در هر پرامپت در همان تاریخ وجودشان بررسی شد.
