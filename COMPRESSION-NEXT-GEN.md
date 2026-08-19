# Next-generation compressor — the brief for a separate session

_Assembled 2026-08-01 from three independent Fable 5 design consultations (video, image, text),
each briefed with the measured results already in this repository. This file is self-contained:
a fresh session should be able to start from it without re-deriving anything._

---

## 0. What exists today, and what it measured

```
packages/connection_orchestrator/lib/src/media_codecs/
  live_context_compressor.dart     the engine — 6 hashed context models (order 0-5), a match
                                   model, a logistic mixer with 4 regime weight sets, APM/SSE,
                                   a 32-bit arithmetic coder; single-pass and streaming
  low_rate_image_compressor.dart   image path
  flipbook_video_compressor.dart   video path
  text_document_compressor.dart    text and document path
  tool/compressor_lab.dart · lab2 · lab3     measurement harnesses over real files
  test/*_compressor_test.dart                four suites, green in the repo test matrix
```

Measured 2026-07-25, tests in the repo:

| input | ours | baseline | delta |
|---|---|---|---|
| 10 KB document text | 1276 B | gzip9 1822 B | −30% |
| repeated Persian text | 136 B | gzip9 254 B | −46.5% |
| Dart source | 5856 B | gzip9 5995 B | −2.3% |
| PCM voice, lpc2 front-end | — | gzip9 | −32.3% |
| screenshot pixels, 2D-Paeth residual | — | PNG-equivalent | −40.1% |
| JPG / PNG bytes as they are | no gain | — | already at entropy |

**Read the last two rows carefully.** The −40.1% is *screenshot* pixels, not photographs. The
"no gain" row is the reason the transfer system must skip already-compressed inputs entirely.

---

## 1. The honest ceiling — stated before any design

All three consultations, run independently, said the same thing without prompting:

- **There is no quantum leap, and no quantum hardware is involved.** Shannon entropy bounds any
  coder on a given source; rate-distortion theory bounds any lossy coder. Nothing here breaks
  that, and claiming it would be false.
- **Context mixing is not new.** cmix, paq8, nncp and the Hutter-Prize line are built on it.
  What this engine is: a clean, small, dependency-free CM coder. That is good engineering, not a
  new category.
- **Where genuine, defensible novelty exists:** not in the ratio, but in the *combination* —
  cmix-family quality inside a phone's memory and speed budget, in pure Dart, with no native
  dependency. Nobody ships cmix on a phone; it needs on the order of 25 GB of RAM and hours of
  CPU. That niche is real and largely empty.

Claims that must never be made: beating cmix/nncp on ratio; beating AVIF or JPEG XL lossy at
matched quality; "world-first context mixing"; anything containing the word quantum.

---

## 2. Text and long documents

### The ceiling, with real baselines

```
enwik8   gzip9      ~36%
         zstd-19    ~30%
         this class ~20-22%   ← realistic target
         cmix/nncp  ~14-15%   ← the gap that will not be closed on a phone
```

The honest baseline is zstd-19, xz-9 and brotli-11 — not gzip. Beating gzip by 30% is table
stakes; every serious codec does it.

### The defect found in the current code — fix this first

`live_context_compressor.dart` keeps history in a `Uint8List(1 << 16)` and masks every access.
**Any file larger than 64 KB silently loses its own past.** For a document compressor this is
the single cheapest large win available. Size the history to the input, capped (≈8 MB desktop,
≈1 MB phone).

### The improvement ladder, by return per unit of work

```
1  history window sized to input          the defect above; biggest cheap win
2  counter state machine                  replace the fixed >>5 adaptation rate and the raw
                                          12-bit counter with a (count, p) pair: fast adaptation
                                          on fresh slots, slow on mature ones. The single
                                          biggest per-model accuracy lever in the paq lineage
3  word / sparse / indirect models         a word-order-1 model (hash of partial word + previous
                                          word), a sparse model skipping bytes at -1/-3, and an
                                          indirect model keyed on the last byte's bit history.
                                          Word models are why paq8 beats zstd on prose
3b PERSIAN: hash at CODEPOINT level        every Persian letter is 2 bytes of UTF-8, so today's
                                          byte-level contexts are split in half. This is a
                                          correctness-shaped bug for Persian, not a tuning knob
4  context-selected mixer weights          promote 4 regime sets to 256-1024 sets selected by
                                          (match regime x last-byte class x order-2 bucket),
                                          plus a second-stage mixer and a 2-stage APM chain
5  second match-model table                a 6-8 byte hash beside the current 4-byte one, prefer
                                          the longer match; lifts source code and repeated text
6  counted preprocessing                   a dictionary built from the file itself and emitted
                                          in the stream. NEVER a shipped prior that is not
                                          counted — a 50 MB prior shipped with the decoder is
                                          50 MB of the answer
```

On small documents (the 10 KB case that matters for this app) cold start dominates, so a small
*counted* priming table (~200-500 KB, generic + Persian) is the largest realistic win — but both
numbers must be reported, with the prior counted and amortized.

### Budgets and gates

```
memory   32 MB phone profile · 256 MB desktop behind a flag
speed    0.5-2 MB/s in Dart, encode and decode symmetric — fine for 10 KB-1 MB documents,
         not a general-purpose codec for 100 MB files. Say so.
gate     beat zstd-19 on every text corpus by >=10%, with the model size counted, and state the
         remaining gap to published cmix numbers honestly
corpora  enwik8[0:1MB] and [0:10MB], a named Persian corpus, this codec's own source
```

---

## 3. Images

### The number that must not be misquoted

The −40.1% was screenshot pixels: flat runs, repeated glyphs, palette-like statistics — exactly
what a hashed context model devours. **Camera photographs are dominated by sensor noise, and
noise is incompressible.** Expect that advantage to shrink sharply on photos, and to be near zero
or negative against JPEG XL lossless until specifically tuned.

### The pipeline

```
A  colour transform    reversible YCoCg-R, integer lifting. Never floating YCbCr.
                       Gate: bit-exact round trip on 10^6 random pixels.
B  prediction          MED/LOCO-I, Paeth, GAP, clamped gradient — either fixed MED or a small
                       predictor-mixing stage weighted by context (this is what JPEG XL's
                       weighted predictor does, and it is the biggest lever after the mixer)
C  context conditioning  THE KEY CHANGE: the order-0..5 byte-hash contexts are the wrong shape
                       for photographs — that is a text and screenshot feature. Replace with
                       2D pixel-domain contexts:
                         quantized local gradients |W-WW|, |N-NN|, |W-N|, ~9 buckets each
                         causal high bits of the current residual
                         the co-located residual of the previous PLANE (cross-channel: Y
                           conditions Co and Cg — the equivalent of JPEG XL's CfL)
                         error feedback: running residual magnitude per context, which maps
                           naturally onto the existing 4 regime weight sets
D  lossy, if at all    near-lossless only, LOCO-I style: clamp residual to +/-delta and feed the
                       reconstruction back into prediction. Reuses the whole lossless machine,
                       2-3x extra at delta 2-4, and keeps the claim honest (a bounded maximum
                       per-pixel error). Do NOT build a DCT psychovisual path — AVIF and JXL
                       VarDCT will not be out-engineered there
```

### Honest verdict per competitor

```
PNG                  clear win expected, 20-45% on photos — but PNG is a strawman, report as a
                     sanity line only
WebP lossless        likely competitive to winning; WebP lossless is weak on photographic content
JPEG XL lossless     THE real bar. Target: within +/-5%. Beating it consistently is unlikely;
                     on noisy high-ISO photos a well-tuned CM coder can edge it — that is the
                     only credible "better than state of the art" niche
AVIF / JXL lossy     no. Never compare lossless bytes to lossy bytes
speed                10-100x slower than libjxl. The sellable property is pure-Dart portability
```

### Budgets and gates

```
memory   fixed-size tables, not growing hashmaps. LOCO-style contexts need a few hundred KB;
         if hashed contexts remain, hard-cap 2^20-2^22 entries — text-style CM tables of
         64-256 MB are fatal on a mid-range Android
speed    >=1 Mpixel/s encode on a phone core (a 12 MP photo in <=12 s is the usability floor)
corpus   >=30 real camera JPEGs DECODED TO RAW RGB, the Kodak set, 10 phone HDR shots
gate     geomean within 5% of `cjxl -d 0 -e 7`, at <=16 MB and >=1 Mpix/s
```

---

## 4. Video

### The ceiling

A CM coder beats standard codecs in exactly one place: the **entropy coding stage**. H.264/AV1
deliberately use cheap entropy coders (CABAC, small fixed contexts) to hit real-time decode. CM
coders beat CABAC-class coding by roughly 5-15% on the same symbols, at 100-10000x the decode
cost.

```
honest claim ceiling   10-25% smaller than x264/libaom at matched PSNR/SSIM, at non-real-time
                       or barely-real-time decode, in pure Dart
false claim            "better than AV1 across the board with real-time phone decode, in Dart,
                       without SIMD or GPU"
lossless video         a different contest: vs FFV1 and x264-lossless, CM can plausibly win
                       20-40%, because lossless is where CM shines and where mainstream codecs
                       invest least
```

### Where the advantage is, and is not

```
IS      entropy coding of residuals and side information with a large adaptive mixed-context
        model; lossless and near-lossless screen content; a model that persists across the whole
        clip instead of resetting per frame
IS NOT  motion estimation (x264's is world class and ours will be worse), transform and
        quantization design, perceptual tuning, decode speed, hardware support
```

### The pipeline

```
1  temporal front-end   block-based motion compensation, 16x16, integer-pel first, previous
                        frame only. Skipping this loses more than CM gains. Motion vectors coded
                        by the CM engine with a context of neighbouring vectors
2  residual             per block choose {motion-compensated residual, 2D-Paeth spatial residual
                        (the existing -40.1% path), skip}, by fewest estimated bits
3  transform            8x8 integer DCT + flat quantizer for the lossy path; for a first
                        milestone skip the transform entirely and quantize residuals directly —
                        measurably worse, but it validates the entropy stage in isolation
4  CM entropy stage     the actual edge. Replace the byte-hash contexts with video contexts:
                        the same coefficient position in the co-located previous-frame block,
                        left and up neighbours, block mode and quantizer, coefficient band,
                        local activity. Keep the logistic mixer and APM.
                        NEVER reset the model between frames — persistence across the clip is
                        precisely what beats CABAC's small contexts
5  frame structure      one I-frame per minute for files; every N seconds if seeking is needed.
                        Serial arithmetic decode is the bottleneck; budget it explicitly
```

### Budgets and gates

```
decode budget   <=33 ms/frame at 720p on an A15-class phone; model tables <=64 MB.
                720p30 is 27.6M pixels/s — real-time is only reachable because most
                coefficients are zero after quantization. If the budget is missed, the honest
                product is a non-real-time archival codec, which is still a real result
corpus          >=3 one-minute clips (natural, screen capture, animation) DECODED TO RAW YUV420
                — never start from MP4 bytes, they are already at entropy
baselines       x264 --preset veryslow and libaom --cpu-used=2 at 3-4 CRF points, compared by
                BD-rate, not single points. Lossless track: FFV1 and x264 -qp 0.
                NEVER PNG-per-frame as a baseline
stage gates     (1) motion front-end + gzip9 residuals must beat intra-Paeth + gzip9, or the
                    motion search is broken
                (2) swap gzip9 for the CM engine — this delta alone is the entire thesis
                (3) full pipeline vs x264 by BD-rate
                (4) decode ms/frame on the MacBook, x4 as a phone proxy until measured on device
                (5) decoder peak RSS
```

---

## 5. PDF

Measured already: PDFs gained roughly 1-2%, because their streams are encrypted or JPEG and are
therefore at entropy. A PDF is a container, so the only route with headroom is to unpack it —
extract text streams, images and fonts, compress each with the front-end that matches it, and
re-emit. That is a container problem, not a codec problem, and it should be scoped separately
from the three codecs above.

---

## 6. Recommended order of work

```
1  text: history window          the defect; cheapest large win, measurable in an afternoon
2  text: Persian codepoint hashing  a correctness issue for Persian, not a tuning knob
3  image: 2D contexts            replaces the wrong-shaped byte-hash contexts; unlocks photos
4  video: lossless screen capture Paeth + temporal skip blocks + CM entropy. This is where the
                                 measured evidence already points, where mainstream codecs are
                                 weakest, and where "best in its class" is actually attainable —
                                 and it de-risks the video contexts before the far harder
                                 natural-video lossy fight
5  text: counter states, word models, contextual mixer
6  PDF container unpacking
```

Every stage lands in `tool/compressor_lab*.dart` with: bytes out, encode ms, decode ms, peak RSS,
and a byte-identical round-trip assertion — against the named baseline for that medium, never
against gzip alone.

---

## 7. The adaptive transfer system this feeds

Designed in the same session; the compressor is its pluggable front-end.

```
decide per chunk     compress if and only if   B < T_c x (1 - r)
                     B    the lane rate adaptive_transport measures
                     T_c  this device's encode throughput, benchmarked once at first run
                     r    expected ratio, from a file-type prior plus a 64 KB probe
                     worked example: T_c = 2 MB/s and r = 0.7 means compress only below
                     0.6 MB/s — fast Wi-Fi sends raw, a bad lane uses the mixer
entropy gate         magic bytes for JPEG/PNG/MP4/ZIP go straight to raw at zero CPU; otherwise
                     a probe ratio above 0.97 switches the rest of the file to raw
chunking             independently decodable chunks, context carried within 1 MB checkpoint
                     groups and reset at group boundaries: resume costs at most one group and
                     never re-compresses delivered data
wire format          MANIFEST {transfer_id, name, len, chunk_count, group_size, sha256,
                     method_bitmap} and CHUNK {idx, method_id, profile_id, raw_len, comp_len,
                     crc32, payload}. method_id 0 = raw and every decoder must implement it —
                     that is the compatibility floor, so version skew never costs a round trip
                     on a bad link. profile_id names the table-size class so the decoder
                     allocates exactly what the encoder used; model state is derived, never shipped
where novelty lives  entirely inside method_id >= 1. The framing, CRC, ARQ and encryption stay
                     deliberately standard — proprietary versions of those buy nothing, are less
                     safe, and break compatibility
```

---

## 8. One paragraph to carry into the new session

The engine is real and its measured wins are real, but the prize is not a bigger ratio than
cmix — it is cmix-class quality inside a phone's budget, in pure Dart, with nothing native
underneath, and that combination is genuinely unoccupied. Start with the 64 KB history window,
because it is a defect rather than a tuning knob; then Persian codepoint hashing, because
byte-level contexts halve every Persian context today; then replace the byte-hash contexts with
2D ones for images. Measure everything against the real competitor for that medium — zstd-19 and
xz for text, JPEG XL lossless for images, x264 and FFV1 for video — and count every byte of any
prior in the output. The word "quantum" never appears in a claim.
