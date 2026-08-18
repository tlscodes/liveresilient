/// Windowed, resumable, content-addressed BINARY transfer over a
/// [DataChannelPort] — the video lane.
///
/// WHY THIS EXISTS (2026-08-08). The chat attachment path base64s payloads
/// into TEXT frames: +~37% wire bytes before the first chunk moves, priced
/// for photos and voice notes, ruinous for a 3-minute camera recording
/// (~400 MB class). This lane sends RAW bytes in compact binary frames on
/// its own negotiated channel (own SCTP stream — a stalled video chunk
/// never head-of-line-blocks chat), and generalizes the two transfer
/// lessons the T2 matrix burned into the attachment path:
///
///   one-in-flight ack pacing  ->  a WINDOW of chunks in flight, sized by
///                                 the link's bandwidth-delay product;
///   drain-aware retransmits   ->  a chunk is re-sent only after silence
///                                 longer than its own drain time.
///
/// RESUMABLE BY CONTENT: the transfer id is the first 16 bytes of the
/// content's SHA-256, and the receiver replies to a HELLO with the bitmap
/// of chunks it already holds — after any disconnect (the matrix's severe
/// profiles drop mid-transfer routinely) a re-offered transfer costs only
/// the chunks that never arrived, never the whole file.
///
/// INTEGRITY: crc32 per chunk (corrupt chunks are dropped and re-sent, the
/// SCTP layer makes this near-theoretical) and whole-content SHA-256
/// verified before the receiver reports completion.
///
/// Pure Dart, transport-agnostic, deterministically testable with an
/// in-memory port pair — no device, no network, no timers it does not own.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'data_channel_port.dart';

/// Frame types on the video lane.
const int _magic = 0xB5;
const int _typeHello = 1; // sender -> receiver: transfer offer
const int _typeHave = 2; // receiver -> sender: bitmap of held chunks
const int _typeChunk = 3; // sender -> receiver: one payload chunk
const int _typeAck = 4; // receiver -> sender: chunk received
const int _typeDone = 5; // receiver -> sender: verified complete
const int _typeProbe = 6; // sender -> receiver: RTT probe, nonce in `index`
const int _typeProbeAck = 7; // receiver -> sender: the nonce echoed back

/// Fixed header: magic(1) type(1) transferId(16) index(4) total(4) len(4).
const int _headerBytes = 30;

/// IEEE 802.3 CRC-32, table-driven; small and dependency-free.
class Crc32 {
  static final Uint32List _table = _build();

  static Uint32List _build() {
    final table = Uint32List(256);
    for (var i = 0; i < 256; i++) {
      var c = i;
      for (var k = 0; k < 8; k++) {
        c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
      }
      table[i] = c;
    }
    return table;
  }

  static int of(List<int> bytes) {
    var c = 0xFFFFFFFF;
    for (final b in bytes) {
      c = _table[(c ^ b) & 0xFF] ^ (c >> 8);
    }
    return (c ^ 0xFFFFFFFF) & 0xFFFFFFFF;
  }
}

/// One decoded lane frame.
class LaneFrame {
  final int type;
  final Uint8List transferId;
  final int index;
  final int total;
  final Uint8List payload;

  LaneFrame(this.type, this.transferId, this.index, this.total, this.payload);

  /// Encodes with the chunk's crc32 appended to payload frames.
  Uint8List encode() {
    final withCrc = type == _typeChunk;
    final out = Uint8List(_headerBytes + payload.length + (withCrc ? 4 : 0));
    final view = ByteData.view(out.buffer);
    out[0] = _magic;
    out[1] = type;
    out.setRange(2, 18, transferId);
    view.setUint32(18, index);
    view.setUint32(22, total);
    view.setUint32(26, payload.length);
    out.setRange(_headerBytes, _headerBytes + payload.length, payload);
    if (withCrc) {
      view.setUint32(_headerBytes + payload.length, Crc32.of(payload));
    }
    return out;
  }

  /// Returns null on anything malformed or corrupt — hostile/garbled input
  /// is dropped, never thrown on.
  static LaneFrame? tryDecode(List<int> raw) {
    if (raw.length < _headerBytes || raw[0] != _magic) return null;
    final bytes = raw is Uint8List ? raw : Uint8List.fromList(raw);
    final view = ByteData.view(bytes.buffer, bytes.offsetInBytes);
    final type = bytes[1];
    if (type < _typeHello || type > _typeProbeAck) return null;
    final len = view.getUint32(26);
    final expected =
        _headerBytes + len + (type == _typeChunk ? 4 : 0);
    if (bytes.length != expected) return null;
    final payload =
        Uint8List.sublistView(bytes, _headerBytes, _headerBytes + len);
    if (type == _typeChunk) {
      final crc = view.getUint32(_headerBytes + len);
      if (crc != Crc32.of(payload)) return null;
    }
    return LaneFrame(
      type,
      Uint8List.sublistView(bytes, 2, 18),
      view.getUint32(18),
      view.getUint32(22),
      payload,
    );
  }
}

/// Outcome of one send.
class BinarySendResult {
  /// Chunks the receiver already held when the transfer started — the
  /// resume dividend, reported so rows can prove resumability happened.
  final int resumedChunks;
  final int totalChunks;

  const BinarySendResult({
    required this.resumedChunks,
    required this.totalChunks,
  });
}

/// Sends one content-addressed binary object with windowed ack pacing.
///
/// ADAPTIVE (2026-08-08, accepted design): the window's DEPTH and the
/// inter-send PACING are not constants — they are re-derived continuously
/// from the acks themselves. Every ack yields an RTT sample (EWMA-smoothed)
/// and the acked-byte counter yields a delivery-rate estimate; the window
/// targets one bandwidth-delay product of data in flight (floor 1, cap
/// [maxWindow]) and sends are paced at the estimated per-chunk drain time,
/// so a tight pipe is never force-fed past what it demonstrably drains —
/// the measured alternative was a flatlined transfer with the transport's
/// buffer as the tombstone.
///
/// PAUSABLE: [pause]/[resume] freeze the send loop instantly (the accepted
/// recovery-freeze design): during a call-recovery episode the caller
/// hands the whole link to signaling; on resume the transfer continues
/// from its ack/HAVE state — content addressing makes the freeze free.
class BinaryStreamSender {
  final DataChannelPort _port;
  final Duration retransmitAfter;
  final int windowSize;
  final int maxWindow;

  /// Live evidence for post-mortems: chunks acked so far and whether the
  /// receiver ever answered HELLO — a timed-out row that cannot say which
  /// leg starved sends the next session back to guessing.
  int ackedChunks = 0;
  bool helloAcked = false;

  /// Smoothed ack round-trip in ms (EWMA, alpha 1/8 like TCP's SRTT) and
  /// the delivery-rate estimate in bytes/s, both measured — never assumed.
  double srttMs = 0;
  double deliveryBytesPerSec = 0;

  /// The floor of every RTT sample seen — the propagation baseline. Pacing
  /// engages only while srtt rides ABOVE 2x this floor (a queue is
  /// demonstrably forming); on a pipe whose delay is propagation, pacing
  /// is pure self-throttle (measured 2026-08-08: it halved the latency
  /// row's probe window into 63 kbit/s).
  double minRttMs = double.infinity;

  /// RTT variance (RFC 6298 shape) backing the adaptive resend deadline,
  /// and the count of retransmissions performed — live evidence: a row
  /// that dies slowly can say whether the sender was thrashing.
  double rttvarMs = 0;
  int retransmitCount = 0;

  /// Last 16 clean (never-retransmitted, Karn-eligible) RTT samples.
  /// [minRttMs] is their min: a WINDOWED floor, because an all-time min
  /// pins a stale low forever if the link's delay rises mid-transfer and
  /// would latch the pacer on a healthy link.
  final List<double> _recentCleanRtts = <double>[];

  /// One-line live evidence for a slow or dying transfer.
  /// Feeds one CLEAN (unambiguous) RTT sample into the RFC 6298
  /// estimator and the windowed floor. Chunk acks provide these only
  /// for never-retransmitted chunks (Karn); RTT probes provide them
  /// unconditionally — every probe nonce is unique, so its echo can
  /// never be mistaken for another transmission's answer.
  void _recordCleanRtt(double sampleMs) {
    if (srttMs == 0) {
      // RFC 6298 seeding: srtt = sample, rttvar = sample/2.
      srttMs = sampleMs;
      rttvarMs = sampleMs / 2;
    } else {
      // RFC 6298 order: rttvar from the OLD srtt, then srtt.
      rttvarMs = rttvarMs * 0.75 + (srttMs - sampleMs).abs() * 0.25;
      srttMs = srttMs * 0.875 + sampleMs * 0.125;
    }
    _recentCleanRtts.add(sampleMs);
    if (_recentCleanRtts.length > 16) {
      _recentCleanRtts.removeAt(0);
    }
    minRttMs =
        _recentCleanRtts.fold(double.infinity, (a, b) => a < b ? a : b);
  }

  String diag() => 'srtt=${srttMs.round()}ms rttvar=${rttvarMs.round()}ms '
      'minRtt=${minRttMs.isFinite ? minRttMs.round() : -1}ms '
      'rate=${(deliveryBytesPerSec * 8 / 1000).round()}kbps '
      'acked=$ackedChunks retx=$retransmitCount helloAcked=$helloAcked';

  bool _paused = false;

  /// Freezes the send loop (in-flight frames drain; nothing new goes out).
  void pause() => _paused = true;

  /// Resumes from the exact ack state — nothing already acked is re-sent.
  void resume() => _paused = false;

  BinaryStreamSender(
    this._port, {
    required this.retransmitAfter,
    this.windowSize = 4,
    this.maxWindow = 16,
    this.chunkBytes = 16 * 1024,
    this.transportBufferedBytes,
    this.sendBudgetBytesPerSec,
  })  : assert(windowSize >= 1),
        assert(chunkBytes >= 512);

  /// Optional LIVE send-rate budget in bytes/second (token bucket, burst
  /// cap two seconds' worth). This is the link arbiter's lever: on a
  /// shared thin pipe the lane must never offer more than its allotted
  /// share, so audio and the call's own control frames keep headroom BY
  /// CONSTRUCTION instead of by racing (measured 2026-08-08 narrow: an
  /// unbudgeted lane plus real audio on 16 kbit/s starved liveness and
  /// the call died mid-transfer, three consecutive runs). Read on every
  /// chunk so the arbiter can retune it mid-transfer; null or a
  /// non-positive return disables the bucket.
  final int Function()? sendBudgetBytesPerSec;

  /// Optional window into the transport's send buffer (standard
  /// RTCDataChannel.bufferedAmount). When provided, NO chunk is handed to
  /// the port while more than one live send window's worth (+1 chunk of
  /// framing slack, floor two chunks) is already queued — the definitive
  /// backpressure signal, scaled by the same BDP-derived window that
  /// depths the send loop (a fixed two-chunk gate starved the pipe on a
  /// 1.8 s round trip). Measured 2026-08-08 (T2 bandwidth):
  /// without it the tail chunks of every long transfer entered a full
  /// buffer whose silent drop was indistinguishable from a dead receiver,
  /// and no pacing heuristic fully replaced knowing the truth.
  final int? Function()? transportBufferedBytes;

  final int chunkBytes;

  /// Sends [bytes]; completes when the receiver has verified the whole
  /// object (DONE frame). Retransmits any un-acked chunk after
  /// [retransmitAfter] of silence for that chunk — drain-aware pacing is
  /// the CALLER's duty via that parameter (pass >= one chunk's drain time
  /// on constrained links).
  Future<BinarySendResult> send(List<int> bytes) async {
    final content = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    final digest = sha256.convert(content).bytes;
    final transferId = Uint8List.fromList(digest.sublist(0, 16));
    final total = (content.length / chunkBytes).ceil().clamp(1, 1 << 31);

    final startedAt = DateTime.now();
    final acked = List<bool>.filled(total, false);
    final lastSentAt = List<DateTime?>.filled(total, null);
    // Karn bookkeeping: a chunk that was EVER retransmitted never yields
    // an RTT sample (its ack is ambiguous — it may answer any copy), and
    // its resend deadline backs off exponentially so a link whose real
    // round trip exceeds the caller's deadline still gets clean samples
    // from not-yet-resent chunks instead of thrashing forever.
    final resent = List<bool>.filled(total, false);
    final resendCount = List<int>.filled(total, 0);
    // Rate numerator: only chunks acked against a send timestamp —
    // resume-bitmap chunks arrive in one burst and would inflate the
    // estimate the pacer divides by.
    var timedAckedChunks = 0;
    // Bootstrap backoff (RFC 6298 §5.5): while NO clean sample exists,
    // every pass that had to resend doubles the effective floor. Without
    // this, a link whose real round trip exceeds the caller's floor
    // resends every fresh chunk once, Karn discards every sample, and
    // the deadline never learns (measured 2026-08-08: 580 s at srtt=0,
    // 391 resends for 367 acks, ~1 chunk per round trip).
    var noSampleBackoff = 1;
    // Whether a CHUNK ack has ever yielded a clean sample. Probe samples
    // seed srtt too, but a header-only probe never pays a chunk's
    // serialization time — on a 16 kbit/s pipe that is ~8 s per chunk —
    // so the bootstrap backoff must stay live until the horizon has been
    // measured against a real chunk (review lens, 2026-08-09: keying it
    // to srtt==0 let a probe-seeded deadline sit one chunk-drain below
    // reality and re-taint every fresh chunk).
    var haveCleanChunkSample = false;
    // RTT PROBES (raised 2026-08-09, honest-loss60 video row): at ~60%
    // e2e loss virtually every chunk is retransmitted at least once, so
    // Karn left the estimator BLIND (measured: srtt=0, minRtt=-1,
    // rate 1 kbps, 4/256 chunks acked in 790 s). A probe is a tiny
    // header-only frame with a unique nonce that is never retransmitted;
    // its echo is always an unambiguous sample. Probes fire only while
    // the estimator is starving (no clean sample in the last 4 s), so a
    // healthy link carries no probe overhead. They deliberately bypass
    // the token bucket: ~60 B per 2 s is 0.4% of the smallest budget,
    // and a starving estimator is exactly when the bucket math needs
    // real numbers.
    var probeNonce = 0;
    final probeSentAt = <int, DateTime>{};
    var lastCleanSampleAt = DateTime.fromMillisecondsSinceEpoch(0);
    // AIMD window state: probe upward, back off on evidence.
    var cwnd = windowSize.toDouble();
    var lastRetxSeen = 0;
    var lastWindowStep = DateTime.now();
    // Token bucket for the live send budget.
    var bucketTokens = 0.0;
    var bucketRefilledAt = DateTime.now();
    final done = Completer<void>();
    var haveBitmap = false;
    var resumed = 0;

    final sub = _port.inbound.listen((raw) {
      final frame = LaneFrame.tryDecode(raw);
      if (frame == null || !_sameId(frame.transferId, transferId)) return;
      switch (frame.type) {
        case _typeHave:
          haveBitmap = true;
          helloAcked = true;
          for (var i = 0; i < total && i < frame.payload.length * 8; i++) {
            if ((frame.payload[i >> 3] >> (i & 7)) & 1 == 1) {
              if (!acked[i]) {
                acked[i] = true;
                resumed++;
                ackedChunks++;
              }
            }
          }
        case _typeAck:
          if (frame.index < total && !acked[frame.index]) {
            acked[frame.index] = true;
            ackedChunks++;
            // Measurement, never assumption — and per Karn's rule only
            // from a chunk never retransmitted: a resend resets its
            // timestamp, and an ack racing that resend yields a bogus
            // near-zero sample. One such sample poisoned minRtt on the
            // 1.8 s rig row, latched the pacer on, and locked the row
            // at ~1 chunk per round trip (measured 2026-08-08).
            final sent = lastSentAt[frame.index];
            if (sent != null) {
              timedAckedChunks++;
              if (!resent[frame.index]) {
                _recordCleanRtt(
                  DateTime.now().difference(sent).inMilliseconds.toDouble(),
                );
                haveCleanChunkSample = true;
                lastCleanSampleAt = DateTime.now();
              }
            }
            final elapsed =
                DateTime.now().difference(startedAt).inMilliseconds;
            if (elapsed > 0) {
              deliveryBytesPerSec =
                  timedAckedChunks * chunkBytes * 1000 / elapsed;
            }
          }
        case _typeDone:
          if (!done.isCompleted) done.complete();
        case _typeProbeAck:
          // Consume the nonce on match: a duplicated echo must not
          // double-sample.
          final probeSent = probeSentAt.remove(frame.index);
          if (probeSent != null) {
            _recordCleanRtt(
              DateTime.now()
                  .difference(probeSent)
                  .inMilliseconds
                  .toDouble(),
            );
            lastCleanSampleAt = DateTime.now();
          }
      }
    });
    final probeTimer =
        Timer.periodic(const Duration(seconds: 2), (_) {
      // Recovery freeze holds for probes too: "nothing new goes out".
      if (done.isCompleted || _paused) return;
      if (DateTime.now().difference(lastCleanSampleAt) <
          const Duration(seconds: 4)) {
        return;
      }
      final nonce = probeNonce++ & 0xFFFFFFFF;
      probeSentAt[nonce] = DateTime.now();
      while (probeSentAt.length > 64) {
        probeSentAt.remove(probeSentAt.keys.first);
      }
      unawaited(
        _port
            .send(
              LaneFrame(_typeProbe, transferId, nonce, total, Uint8List(0))
                  .encode(),
            )
            .catchError((Object _) {}),
      );
    });

    // Live send window (chunks) — ONE binding shared by the fill loop
    // below (which recomputes it from measured BDP each pass) and the
    // backpressure gate in sendChunk. The loop ASSIGNS, never
    // re-declares: a shadowing `var` there would silently pin the gate
    // back to the floor with zero analyzer warning.
    var window = windowSize;

    Future<void> sendChunk(int i) async {
      // RATE BUDGET (token bucket): before anything else, wait until the
      // arbiter's live budget covers one chunk. Refill is continuous at
      // the current rate; burst cap is two seconds' worth so a paused
      // bucket cannot dump a backlog onto a thin pipe all at once.
      final budgetFn = sendBudgetBytesPerSec;
      if (budgetFn != null) {
        while (!done.isCompleted && !_paused) {
          final rate = budgetFn();
          if (rate <= 0) break;
          final now = DateTime.now();
          final dtMs = now.difference(bucketRefilledAt).inMilliseconds;
          bucketRefilledAt = now;
          // Burst cap: two seconds' worth, but NEVER below one chunk —
          // a cap under the chunk size makes the wait unsatisfiable and
          // wedges the transfer at zero forever (measured 2026-08-08
          // narrow run 5: budget 500 B/s, chunk 4 KiB, cap 1000 B →
          // helloAcked with 0 chunks ever sent in 1500 s).
          final burstCap =
              rate * 2.0 < chunkBytes ? chunkBytes.toDouble() : rate * 2.0;
          bucketTokens =
              (bucketTokens + rate * dtMs / 1000).clamp(0.0, burstCap);
          if (bucketTokens >= chunkBytes) {
            bucketTokens -= chunkBytes;
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        if (done.isCompleted || _paused) return;
      }
      // BACKPRESSURE GATE: while the transport holds more un-drained
      // bytes than one live window's worth, WAIT — a frame handed over
      // now would sit in (or fall off) that queue, not travel. The
      // threshold derives from the BDP-scaled window (floor: two
      // chunks; +1 chunk slack because bufferedAmount counts encoded
      // framing, so an exact product trips one chunk early) and is read
      // live on every poll, so it tracks the window as measurements
      // arrive instead of freezing the pre-measurement floor. Bounded:
      // give up the wait after retransmitAfter and let the outer loop
      // re-evaluate.
      final buffered = transportBufferedBytes;
      if (buffered != null) {
        int gateBytes() {
          final windowBytes = ((window < 2 ? 2 : window) + 1) * chunkBytes;
          // DRAIN-TIME BOUND: on a thin pipe what matters is the queue's
          // WIRE TIME, not its chunk count — a backlog the link needs
          // tens of seconds to drain starves the call's own heartbeats
          // (measured 2026-08-08 narrow, 16 kbit/s: five queued chunks
          // made srtt 36 s and the call died mid-transfer, twice). Cap
          // the backlog at ~8 s of measured drain, never below the
          // two-chunk floor; before a rate sample exists the window
          // bound stands alone.
          if (deliveryBytesPerSec > 0) {
            final drainBytes = (deliveryBytesPerSec * 8).round();
            final floorBytes = 2 * chunkBytes;
            final capped = drainBytes < floorBytes ? floorBytes : drainBytes;
            return capped < windowBytes ? capped : windowBytes;
          }
          return windowBytes;
        }

        final waitDeadline = DateTime.now().add(retransmitAfter);
        while ((buffered() ?? 0) > gateBytes() &&
            DateTime.now().isBefore(waitDeadline) &&
            !done.isCompleted &&
            !_paused) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        if (done.isCompleted || _paused) return;
      }
      final start = i * chunkBytes;
      final end =
          (start + chunkBytes) > content.length ? content.length : start + chunkBytes;
      lastSentAt[i] = DateTime.now();
      await _port.send(
        LaneFrame(
          _typeChunk,
          transferId,
          i,
          total,
          Uint8List.sublistView(content, start, end),
        ).encode(),
      );
    }

    try {
      // HELLO announces (id, total, size) and is RETRANSMITTED until the
      // receiver's HAVE bitmap arrives — the bitmap doubles as HELLO's
      // ack. A single un-acked HELLO on a lossy link would orphan every
      // chunk (the receiver drops chunks for unknown transfers, because a
      // chunk alone does not carry the object's size), and the first
      // in-memory loss test caught exactly that.
      final sizePayload = Uint8List(8)
        ..buffer.asByteData().setUint64(0, content.length);
      final hello =
          LaneFrame(_typeHello, transferId, 0, total, sizePayload).encode();
      await _port.send(hello);
      var helloSentAt = DateTime.now();
      while (!haveBitmap && !done.isCompleted) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
        if (!haveBitmap &&
            DateTime.now().difference(helloSentAt) >= retransmitAfter) {
          await _port.send(hello);
          helloSentAt = DateTime.now();
        }
      }

      while (!done.isCompleted) {
        if (_paused) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          continue;
        }
        // ADAPTIVE WINDOW: target one measured bandwidth-delay product in
        // flight — (deliveryRate x srtt) / chunk — clamped to
        // [1, maxWindow]; before the first measurements exist the
        // configured floor applies. A fat long pipe deepens the window on
        // evidence; a thin pipe collapses to stop-and-wait on evidence.
        // The configured windowSize is the PROBE FLOOR, never undercut: a
        // delivery rate measured under a shrunken window is depressed by
        // that very window (measured 2026-08-08, latency row: BDP said 1,
        // stop-and-wait said 19 kbit/s, and each kept the other true —
        // the classic self-confirming under-estimate that rate-based
        // congestion control solves by always probing). The floor probes;
        // the PACING below still protects thin pipes regardless of depth.
        // ADAPTIVE WINDOW v2 — PROBE, never self-confirm. The previous
        // law computed a BDP from the measured delivery rate, but a rate
        // measured under window W is at most W per round trip, so the
        // computed BDP always mirrored the current window back and the
        // window could never rise above its floor (measured 2026-08-08
        // run 4: window pinned at 4, srtt 4.3 s, rate 99 kbps, 440/512
        // chunks — clean link, no resends, still starved). AIMD instead:
        // +1 chunk per smoothed round trip while the interval stayed
        // clean; halve — never below the floor — when it saw a resend.
        // The pacing and the buffered-bytes gate below remain the guards
        // that stop the probe from force-feeding a thin pipe.
        if (srttMs > 0) {
          final growIntervalMs = srttMs.round().clamp(200, 10000);
          if (DateTime.now().difference(lastWindowStep).inMilliseconds >=
              growIntervalMs) {
            lastWindowStep = DateTime.now();
            if (retransmitCount > lastRetxSeen) {
              cwnd = (cwnd / 2)
                  .clamp(windowSize.toDouble(), maxWindow.toDouble());
            } else if (cwnd < maxWindow) {
              cwnd += 1;
            }
            lastRetxSeen = retransmitCount;
          }
        }
        window = cwnd.round().clamp(windowSize, maxWindow);
        // Fill the window with the lowest un-acked, un-inflight chunks;
        // re-send any chunk silent past retransmitAfter. Sends are PACED
        // at the measured per-chunk drain time so the transport's buffer
        // holds a window, never a backlog.
        var inFlight = 0;
        final now = DateTime.now();
        // Adaptive resend deadline: the caller's retransmitAfter is a
        // POLICY FLOOR, raised (never lowered) to srtt + 4*rttvar once
        // clean samples exist — a healthy ack on a long link must not
        // be mistaken for loss. Per-chunk exponential backoff (capped
        // 8x / 60 s) is Karn's second half: without it, a link whose
        // round trip always exceeds the floor would resend every chunk
        // forever and never obtain a clean sample to raise the deadline.
        var rtoMs = retransmitAfter.inMilliseconds;
        if (srttMs > 0) {
          final adaptive = (srttMs + 4 * rttvarMs).round();
          if (adaptive > rtoMs) rtoMs = adaptive;
        }
        if (!haveCleanChunkSample) {
          // No clean CHUNK sample yet — keep the bootstrap backoff live
          // as a FLOOR even when probe samples have seeded srtt: a
          // header-only probe never pays a chunk's serialization time,
          // so a probe-seeded adaptive deadline can sit one chunk-drain
          // below the real ack horizon and re-taint every fresh chunk.
          // Released the moment a chunk ack yields a clean sample.
          final backedOff = (retransmitAfter.inMilliseconds * noSampleBackoff)
              .clamp(retransmitAfter.inMilliseconds, 60000);
          if (backedOff > rtoMs) rtoMs = backedOff;
        }
        // Hard ceiling AFTER both branches: the per-chunk deadline below
        // clamps into [rtoMs, 60000], and Dart's clamp THROWS if its
        // lower bound crosses its upper one (measured 2026-08-08 run 3:
        // adaptive srtt + 4*rttvar hit 120117 ms on the slow-started
        // link and crashed the transfer mid-flight).
        if (rtoMs > 60000) rtoMs = 60000;
        var unseededResend = false;
        for (var i = 0; i < total && inFlight < window; i++) {
          if (acked[i]) continue;
          final sent = lastSentAt[i];
          final deadlineMs =
              (rtoMs * (1 << resendCount[i].clamp(0, 3))).clamp(rtoMs, 60000);
          if (sent == null ||
              now.difference(sent).inMilliseconds >= deadlineMs) {
            if (sent != null) {
              // Karn flag BEFORE the await: the ack can land during the
              // suspension and must not be sampled against either copy.
              resent[i] = true;
              resendCount[i]++;
              retransmitCount++;
              if (!haveCleanChunkSample) unseededResend = true;
            }
            await sendChunk(i);
            if (acked[i]) {
              // Acked during the await — no longer in flight, and a
              // pacer sleep for it would be pure waste.
              continue;
            }
            // Pace ONLY on queue evidence: srtt inflated to twice the
            // measured propagation floor means the bottleneck buffer is
            // filling and each send must wait its drain slot. A flat srtt
            // means the pipe is draining at wire speed and delay here is
            // pure self-throttle.
            final queueForming = minRttMs.isFinite && srttMs > 2 * minRttMs;
            if (queueForming && deliveryBytesPerSec > 0) {
              final drainMs =
                  (chunkBytes * 1000 / deliveryBytesPerSec / window).round();
              if (drainMs > 0) {
                await Future<void>.delayed(
                  Duration(milliseconds: drainMs.clamp(0, 2000)),
                );
              }
            }
          }
          inFlight++;
        }
        if (unseededResend && noSampleBackoff < 16) noSampleBackoff *= 2;
        if (acked.every((a) => a)) {
          // All acked; wait for the receiver's DONE (its SHA verdict).
          await done.future.timeout(
            retransmitAfter * 4,
            onTimeout: () => throw TimeoutException(
              'receiver never confirmed content hash after all chunks acked',
            ),
          );
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
      return BinarySendResult(resumedChunks: resumed, totalChunks: total);
    } finally {
      probeTimer.cancel();
      unawaited(sub.cancel());
    }
  }

  static bool _sameId(Uint8List a, Uint8List b) {
    for (var i = 0; i < 16; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// A completed inbound binary object.
class BinaryReceived {
  final Uint8List transferId;
  final Uint8List bytes;
  final bool sha256Ok;

  BinaryReceived(this.transferId, this.bytes, this.sha256Ok);
}

/// Receives content-addressed binary objects; persistence of partials is
/// the caller's choice via [exportPartial]/restore in the constructor.
class BinaryStreamReceiver {
  final DataChannelPort _port;
  final _completed = StreamController<BinaryReceived>.broadcast();
  final _partials = <String, _RxPartial>{};

  /// Recently completed transfer ids (bounded FIFO): a sender whose DONE
  /// frame was lost keeps retransmitting — any frame for a completed id is
  /// answered with a fresh DONE instead of silence, or the sender would
  /// retry until its own timeout on precisely the links this lane exists
  /// for.
  static const int _maxCompletedIds = 64;
  final _completedIds = <String>{};
  late final StreamSubscription<List<int>> _sub;

  BinaryStreamReceiver(this._port) {
    _sub = _port.inbound.listen(_onFrame, onError: (_, __) {});
  }

  Stream<BinaryReceived> get completed => _completed.stream;

  /// Restores a previously exported partial (resume across restarts).
  void restorePartial(Uint8List transferId, Map<int, Uint8List> chunks,
      {required int total, required int sizeBytes}) {
    _partials[_key(transferId)] =
        _RxPartial(total, sizeBytes)..parts.addAll(chunks);
  }

  Future<void> _onFrame(List<int> raw) async {
    final frame = LaneFrame.tryDecode(raw);
    if (frame == null) return;
    final key = _key(frame.transferId);
    if (_completedIds.contains(key)) {
      await _port.send(
        LaneFrame(_typeDone, frame.transferId, 0, frame.total, Uint8List(0))
            .encode(),
      );
      return;
    }
    switch (frame.type) {
      case _typeHello:
        final size = ByteData.view(
          frame.payload.buffer,
          frame.payload.offsetInBytes,
        ).getUint64(0);
        final partial =
            _partials.putIfAbsent(key, () => _RxPartial(frame.total, size));
        // Reply with what we already hold — the resume dividend.
        final bitmap = Uint8List((frame.total + 7) >> 3);
        for (final i in partial.parts.keys) {
          bitmap[i >> 3] |= 1 << (i & 7);
        }
        await _port.send(
          LaneFrame(_typeHave, frame.transferId, 0, frame.total, bitmap)
              .encode(),
        );
      case _typeProbe:
        // Echo immediately: the sender's RTT estimator depends on this
        // being the fastest possible turnaround (no state, no disk).
        await _port.send(
          LaneFrame(_typeProbeAck, frame.transferId, frame.index,
                  frame.total, Uint8List(0))
              .encode(),
        );
      case _typeChunk:
        final partial = _partials[key];
        if (partial == null || frame.index >= partial.total) return;
        partial.parts[frame.index] = Uint8List.fromList(frame.payload);
        await _port.send(
          LaneFrame(_typeAck, frame.transferId, frame.index, frame.total,
                  Uint8List(0))
              .encode(),
        );
        if (partial.parts.length == partial.total) {
          final builder = BytesBuilder(copy: false);
          for (var i = 0; i < partial.total; i++) {
            builder.add(partial.parts[i]!);
          }
          final bytes = builder.toBytes();
          final digest = sha256.convert(bytes).bytes;
          final ok = _prefixMatches(digest, frame.transferId) &&
              bytes.length == partial.sizeBytes;
          if (ok) {
            _partials.remove(key);
            _completedIds.add(key);
            while (_completedIds.length > _maxCompletedIds) {
              _completedIds.remove(_completedIds.first);
            }
            await _port.send(
              LaneFrame(_typeDone, frame.transferId, 0, partial.total,
                      Uint8List(0))
                  .encode(),
            );
          }
          if (!_completed.isClosed) {
            _completed.add(
              BinaryReceived(frame.transferId, bytes, ok),
            );
          }
        }
      default:
        return;
    }
  }

  static bool _prefixMatches(List<int> digest, Uint8List id) {
    for (var i = 0; i < 16; i++) {
      if (digest[i] != id[i]) return false;
    }
    return true;
  }

  static String _key(Uint8List id) =>
      id.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  Future<void> close() async {
    unawaited(_sub.cancel());
    await _completed.close();
  }
}

class _RxPartial {
  final int total;
  final int sizeBytes;
  final parts = <int, Uint8List>{};
  _RxPartial(this.total, this.sizeBytes);
}
