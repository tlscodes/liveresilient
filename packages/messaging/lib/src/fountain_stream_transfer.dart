/// Rateless (fountain) BINARY transfer over a [DataChannelPort] — the
/// video lane for links where ARQ dies.
///
/// WHY THIS EXISTS (2026-08-10). Measured on the T2 rig: at 60% random
/// e2e loss the ARQ lane collapses to ~1 kbps — every chunk needs its own
/// ack round trip, SCTP's loss-based congestion control interprets random
/// loss as catastrophe, and 4 MB can never fit any window. This lane
/// removes retransmission entirely: content is encoded as SYSTEMATIC
/// RANDOM LINEAR NETWORK CODING (RLNC) over GF(256) in generation windows;
/// the receiver reconstructs a generation from ANY `G` linearly
/// independent symbols. Loss costs proportional extra symbols, never a
/// round trip.
///
/// HARD PRECONDITION — CHANNEL CONFIG: this lane must be bound to a data
/// channel negotiated `ordered: false, maxRetransmits: 0`. On a reliable
/// channel SCTP retransmits underneath and rebuilds the exact collapse
/// this lane exists to escape. The port interface cannot assert it; the
/// binding site owns it.
///
/// Feedback is a low-rate periodic STATE frame (cumulative progress +
/// per-generation rank vector), never per-symbol acks. Rate control is
/// delivery-driven (never loss-triggered): send rate chases measured
/// decode rate with loss headroom, hard-capped at a small multiple of the
/// delivery rate, and gated on the transport's own buffered bytes.
///
/// RESUMABLE BY CONTENT like the ARQ lane: transferId = first 16 bytes of
/// the content SHA-256; a re-offered transfer skips completed generations
/// (and skips the systematic pass of any generation with partial rank —
/// rank `r` does not say WHICH unit vectors are held, so a systematic
/// re-send is dead weight with probability r/G; repair-only is strictly
/// better there). Integrity: crc32 per symbol, whole-content SHA-256
/// before DONE.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'binary_stream_transfer.dart' show Crc32;
import 'data_channel_port.dart';

/// Frame magic for the fountain lane — deliberately NOT the ARQ lane's
/// 0xB5: the two decoders stay fully independent.
const int _magic = 0xF7;
const int _typeHello = 1; // sender -> receiver: transfer offer
const int _typeState = 2; // receiver -> sender: cumulative progress
const int _typeSymbol = 3; // sender -> receiver: one coded symbol
const int _typeDone = 4; // receiver -> sender: sha-verified complete

/// Fixed header: magic(1) type(1) transferId(16) a(4) b(4) len(4).
/// SYMBOL: a=generation, b=seq (seq < G means systematic unit vector
/// e_seq; seq >= G means repair with PRNG coefficients — see
/// [_coefficientsFor]); payload + crc32(4).
/// HELLO: a=symbolBytes, b=generationSize, payload=sizeBytes as uint64.
/// STATE: a=cumulative decoded symbols (sum of ranks — monotone),
/// b=generation count, payload = completed bitmap + rank vector.
/// DONE: empty payload.
const int _headerBytes = 30;

/// GF(256) (AES polynomial 0x11B) with a flat 64 KiB multiplication table:
/// the hot row operation is `t[i] ^= mul[(c << 8) | s[i]]` — two loads, one
/// xor, one store, no branch. log/exp exist only to compute inverses.
class _Gf {
  static final Uint8List mul = _buildMul();
  static final Uint8List inv = _buildInv();

  static Uint8List _buildMul() {
    final table = Uint8List(65536);
    for (var a = 1; a < 256; a++) {
      for (var b = 1; b < 256; b++) {
        var x = a, y = b, p = 0;
        while (y != 0) {
          if (y & 1 != 0) p ^= x;
          x <<= 1;
          if (x & 0x100 != 0) x ^= 0x11B;
          y >>= 1;
        }
        table[(a << 8) | b] = p;
      }
    }
    return table;
  }

  static Uint8List _buildInv() {
    final table = Uint8List(256);
    for (var a = 1; a < 256; a++) {
      for (var b = 1; b < 256; b++) {
        if (mul[(a << 8) | b] == 1) {
          table[a] = b;
          break;
        }
      }
    }
    return table;
  }

  /// target ^= coeff * source (byte-wise over GF(256)).
  static void addScaled(Uint8List target, Uint8List source, int coeff) {
    if (coeff == 0) return;
    if (coeff == 1) {
      for (var i = 0; i < target.length; i++) {
        target[i] ^= source[i];
      }
      return;
    }
    final m = mul;
    final base = coeff << 8;
    for (var i = 0; i < target.length; i++) {
      target[i] ^= m[base | source[i]];
    }
  }

  /// row *= coeff (in place).
  static void scale(Uint8List row, int coeff) {
    if (coeff == 1) return;
    final m = mul;
    final base = coeff << 8;
    for (var i = 0; i < row.length; i++) {
      row[i] = m[base | row[i]];
    }
  }
}

/// Deterministic repair coefficients from (generation, seq): both ends run
/// the same Dart, so the frame needs no coefficient vector. PRNG is
/// xorshift32 seeded from the pair; an all-zero draw re-rolls (the
/// receiver derives identically, so both see the same final vector).
Uint8List _coefficientsFor(int generation, int seq, int g) {
  var s = (generation * 0x9E3779B1) ^ (seq * 0x85EBCA77) ^ 0x5F356495;
  s &= 0xFFFFFFFF;
  if (s == 0) s = 1; // xorshift32 fixed point — never spin on zero.
  final out = Uint8List(g);
  var allZero = true;
  do {
    for (var i = 0; i < g; i++) {
      s ^= s << 13;
      s &= 0xFFFFFFFF;
      s ^= s >> 17;
      s ^= s << 5;
      s &= 0xFFFFFFFF;
      out[i] = s & 0xFF;
      if (out[i] != 0) allZero = false;
    }
  } while (allZero);
  return out;
}

class _FountainFrame {
  final int type;
  final Uint8List transferId;
  final int a;
  final int b;
  final Uint8List payload;

  _FountainFrame(this.type, this.transferId, this.a, this.b, this.payload);

  Uint8List encode() {
    final withCrc = type == _typeSymbol;
    final out = Uint8List(_headerBytes + payload.length + (withCrc ? 4 : 0));
    final view = ByteData.view(out.buffer);
    out[0] = _magic;
    out[1] = type;
    out.setRange(2, 18, transferId);
    view.setUint32(18, a);
    view.setUint32(22, b);
    view.setUint32(26, payload.length);
    out.setRange(_headerBytes, _headerBytes + payload.length, payload);
    if (withCrc) {
      view.setUint32(_headerBytes + payload.length, Crc32.of(payload));
    }
    return out;
  }

  static _FountainFrame? tryDecode(List<int> raw) {
    if (raw.length < _headerBytes || raw[0] != _magic) return null;
    final bytes = raw is Uint8List ? raw : Uint8List.fromList(raw);
    final view = ByteData.view(bytes.buffer, bytes.offsetInBytes);
    final type = bytes[1];
    if (type < _typeHello || type > _typeDone) return null;
    final len = view.getUint32(26);
    final expected = _headerBytes + len + (type == _typeSymbol ? 4 : 0);
    if (bytes.length != expected) return null;
    final payload = Uint8List.sublistView(
      bytes,
      _headerBytes,
      _headerBytes + len,
    );
    if (type == _typeSymbol) {
      if (view.getUint32(_headerBytes + len) != Crc32.of(payload)) {
        return null;
      }
    }
    return _FountainFrame(
      type,
      Uint8List.sublistView(bytes, 2, 18),
      view.getUint32(18),
      view.getUint32(22),
      payload,
    );
  }
}

String _idKey(Uint8List id) =>
    id.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// Outcome of one fountain send.
class FountainSendResult {
  /// Generations the receiver already held complete at HELLO time.
  final int resumedGenerations;
  final int totalGenerations;

  /// Total symbols emitted — with [totalSourceSymbols] this is the
  /// measured overhead, reported so rig rows carry the real number.
  final int sentSymbols;
  final int totalSourceSymbols;

  const FountainSendResult({
    required this.resumedGenerations,
    required this.totalGenerations,
    required this.sentSymbols,
    required this.totalSourceSymbols,
  });
}

/// Sends one content-addressed object as rateless coded symbols.
class FountainStreamSender {
  FountainStreamSender(
    this._port, {
    this.symbolBytes = 16 * 1024,
    this.generationSize = 32,
    this.stateInterval = const Duration(milliseconds: 500),
    this.staleAfter = const Duration(seconds: 45),
    this.rateCapFactor = 4.0,
    this.floorBytesPerSec = 16 * 1024,
    this.transportBufferedBytes,
    int? transportGateBytes,
  }) : transportGateBytes = transportGateBytes ?? 2 * symbolBytes,
       assert(symbolBytes > 0),
       assert(generationSize >= 1 && generationSize <= 255);

  final DataChannelPort _port;
  final int symbolBytes;

  /// 1..255: the STATE rank vector is one byte per generation (L2).
  final int generationSize;

  /// HELLO retransmit cadence, and the pacing tick.
  final Duration stateInterval;

  /// Terminal condition the rateless design otherwise lacks: with no
  /// STATE of any kind for this long, the reverse path is dead and repair
  /// symbols would flow forever.
  final Duration staleAfter;

  /// Hard cap: send rate never exceeds this multiple of the measured
  /// delivery rate — the anti-runaway guard (a loss-headroom multiplier
  /// alone ACCELERATES under congestion loss).
  final double rateCapFactor;

  /// Bootstrap floor before any delivery estimate exists.
  final int floorBytesPerSec;

  /// Same closed-loop guard as the ARQ lane: when the transport reports
  /// its buffered backlog, symbol emission pauses past [transportGateBytes]
  /// of queue — an unreliable channel still buffers locally, and local
  /// drops would masquerade as channel loss to the estimator.
  final int? Function()? transportBufferedBytes;

  /// Backlog level that pauses emission. Default two symbols — the tightest
  /// honest pacing. MEASURED CAVEAT (T2 loss60 shot 1, 2026-08-10): a
  /// transport whose bufferedAmount is a cached, event-refreshed value can
  /// hold the tight gate shut nearly always and clamp the lane to the
  /// cache-refresh cadence (~1.5 symbols/s observed while the wire carried
  /// every packet offered). Binding sites on such transports should pass a
  /// gate of a few seconds' worth of floor rate: still far below any
  /// transport close-cliff, but immune to refresh-cadence throttling.
  final int transportGateBytes;

  /// Live evidence for post-mortems (same discipline as the ARQ lane).
  int sentSymbols = 0;
  int lastCumulativeDecoded = 0;
  double deliveryBytesPerSec = 0;
  double lossEstimate = 0;
  bool helloAcked = false;

  String diag() =>
      'sent=$sentSymbols decoded=$lastCumulativeDecoded '
      'rate=${(deliveryBytesPerSec * 8 / 1000).round()}kbps '
      'loss=${(lossEstimate * 100).round()}% helloAcked=$helloAcked';

  Future<FountainSendResult> send(List<int> bytes) async {
    // Per-send state: telemetry fields are INSTANCE state for post-mortem
    // reads, so a reused sender must reset them or the second transfer
    // skips HELLO and starves (review H1, 2026-08-10).
    sentSymbols = 0;
    lastCumulativeDecoded = 0;
    deliveryBytesPerSec = 0;
    lossEstimate = 0;
    helloAcked = false;

    final content = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    final digest = sha256.convert(content).bytes;
    final transferId = Uint8List.fromList(digest.sublist(0, 16));
    final totalSymbols = (content.length / symbolBytes).ceil().clamp(
      1,
      1 << 31,
    );
    final generations = (totalSymbols / generationSize).ceil();

    // Source symbols, zero-padded to symbolBytes (the ragged tail too —
    // HELLO carries the true byte size so the receiver trims).
    // Cached source symbols: repair encoding touches every symbol of a
    // generation per emitted symbol — re-slicing fresh buffers in that
    // loop was pure GC churn (review L4).
    final sourceCache = List<Uint8List?>.filled(totalSymbols, null);
    Uint8List symbolAt(int index) {
      final cached = sourceCache[index];
      if (cached != null) return cached;
      final start = index * symbolBytes;
      final end = (start + symbolBytes).clamp(0, content.length);
      final out = Uint8List(symbolBytes);
      out.setRange(0, end - start, Uint8List.sublistView(content, start, end));
      sourceCache[index] = out;
      return out;
    }

    int genSize(int g) {
      final remaining = totalSymbols - g * generationSize;
      return remaining < generationSize ? remaining : generationSize;
    }

    final completed = List<bool>.filled(generations, false);
    final ranks = List<int>.filled(generations, 0);
    final sentSinceState = List<int>.filled(generations, 0);
    final systematicSent = List<int>.filled(generations, 0);
    // Monotone per-generation repair sequence: NEVER reset (a rewound seq
    // is an identical coefficient vector = pure waste — review H3). A
    // fresh sender decorrelates from any earlier run of the same content
    // via a time-derived offset; determinism is unaffected because seq
    // travels in the frame.
    final seqOffset =
        (DateTime.now().microsecondsSinceEpoch & 0x3FFF) * 131 + 1;
    final repairSeq = List<int>.filled(generations, 0);
    var resumedGenerations = 0;
    var resumeApplied = false;
    var firstStateSeen = false;
    var lastStateAt = DateTime.now();
    var lastRateSampleAt = DateTime.now();
    var lastRateSampleDecoded = 0;
    var sentSinceSample = 0;
    final done = Completer<void>();

    void applyState(_FountainFrame frame) {
      // Geometry guard: a STATE whose generation count disagrees with
      // this transfer is not ours to interpret (review M2).
      if (frame.b != generations) return;
      lastStateAt = DateTime.now();
      helloAcked = true;
      final genCount = frame.b;
      final bitmapBytes = (genCount + 7) >> 3;
      if (frame.payload.length < bitmapBytes + genCount) return;
      final stale = frame.a < lastCumulativeDecoded;
      // Window accounting BEFORE any counter reset (review H2): the
      // sample accumulator collects everything sent since the previous
      // rate sample, across however many STATEs arrive in between.
      if (!stale) {
        sentSinceSample += sentSinceState.fold(0, (a, b) => a + b);
      }
      var allComplete = genCount > 0;
      for (var g = 0; g < genCount; g++) {
        final isComplete = (frame.payload[g >> 3] >> (g & 7)) & 1 == 1;
        if (isComplete && !completed[g]) {
          completed[g] = true;
          if (!resumeApplied) resumedGenerations++;
        }
        if (!isComplete) allComplete = false;
        final rank = frame.payload[bitmapBytes + g];
        if (rank > ranks[g]) ranks[g] = rank;
        // A stale (out-of-order) STATE must not re-open debt caps
        // (review L3).
        if (!stale) sentSinceState[g] = 0;
      }
      final cumulative = frame.a;
      if (cumulative > lastCumulativeDecoded) {
        lastCumulativeDecoded = cumulative;
      }
      final now = DateTime.now();
      if (!firstStateSeen) {
        // Resume baseline: the first STATE carries the receiver's full
        // history — counting it as fresh delivery produced a bogus
        // multi-MB/s first estimate (review M1).
        firstStateSeen = true;
        lastRateSampleAt = now;
        lastRateSampleDecoded = lastCumulativeDecoded;
        sentSinceSample = 0;
      } else {
        final dtMs = now.difference(lastRateSampleAt).inMilliseconds;
        if (dtMs >= 250) {
          final decodedDelta = lastCumulativeDecoded - lastRateSampleDecoded;
          deliveryBytesPerSec = decodedDelta * symbolBytes * 1000 / dtMs;
          if (sentSinceSample > 0) {
            final missFraction =
                1 - (decodedDelta / sentSinceSample).clamp(0.0, 1.0);
            lossEstimate = lossEstimate * 0.7 + missFraction * 0.3;
          }
          lastRateSampleAt = now;
          lastRateSampleDecoded = lastCumulativeDecoded;
          sentSinceSample = 0;
        }
      }
      if (allComplete && !done.isCompleted) {
        // A string of lost DONEs must not stall the sender: an
        // all-complete bitmap IS completion evidence.
        done.complete();
      }
      resumeApplied = true;
    }

    final sub = _port.inbound.listen((raw) {
      final frame = _FountainFrame.tryDecode(raw);
      if (frame == null) return;
      if (_idKey(frame.transferId) != _idKey(transferId)) return;
      switch (frame.type) {
        case _typeState:
          applyState(frame);
        case _typeDone:
          if (!done.isCompleted) done.complete();
      }
    });

    final sizePayload = Uint8List(8)
      ..buffer.asByteData().setUint64(0, content.length);
    final hello = _FountainFrame(
      _typeHello,
      transferId,
      symbolBytes,
      generationSize,
      sizePayload,
    ).encode();

    try {
      // Register first: symbols sent before the receiver knows the
      // transfer are orphans. HELLO retransmits until the first STATE
      // answers it (~six tries expected at 60% bidirectional loss).
      while (!helloAcked && !done.isCompleted) {
        await _port.send(hello);
        if (DateTime.now().difference(lastStateAt) > staleAfter) {
          throw TimeoutException(
            'fountain receiver never answered HELLO (${diag()})',
          );
        }
        await Future<void>.delayed(stateInterval);
      }

      var bucketBytes = 0.0;
      var refilledAt = DateTime.now();
      var rotor = 0;
      var lastSolicitAt = DateTime.fromMillisecondsSinceEpoch(0);
      while (!done.isCompleted) {
        if (DateTime.now().difference(lastStateAt) > staleAfter) {
          throw TimeoutException('fountain STATE silence (${diag()})');
        }
        // Delivery-driven refill: chase the decode rate with loss
        // headroom, never exceed rateCapFactor x measured delivery, and
        // never fall below the floor. The floor binds ALWAYS, not only
        // before the first sample: target = delivery x headroom exactly
        // reproduces the current rate (a neutral equilibrium), so any
        // downward transient would otherwise become the permanent level —
        // measured on the 4 MiB / 60% relay probe (2026-08-10): average
        // delivery sat at ~9 KiB/s against a 32 KiB/s floor.
        final headroom = 1 / (1 - lossEstimate.clamp(0.0, 0.75));
        var targetRate = deliveryBytesPerSec > 0
            ? deliveryBytesPerSec * headroom
            : floorBytesPerSec.toDouble();
        final cap = deliveryBytesPerSec > 0
            ? deliveryBytesPerSec * rateCapFactor
            : floorBytesPerSec.toDouble();
        if (targetRate > cap) targetRate = cap;
        // Floor LAST: it is the operator's explicit lower bound, so it wins
        // over the anti-runaway cap when a transient drags delivery down.
        if (targetRate < floorBytesPerSec) {
          targetRate = floorBytesPerSec.toDouble();
        }
        final now = DateTime.now();
        bucketBytes +=
            targetRate * now.difference(refilledAt).inMilliseconds / 1000.0;
        final maxBucket = targetRate.clamp(
          symbolBytes.toDouble(),
          (1 << 24).toDouble(),
        );
        if (bucketBytes > maxBucket) bucketBytes = maxBucket;
        refilledAt = now;

        final buffered = transportBufferedBytes?.call();
        if ((buffered != null && buffered > transportGateBytes) ||
            bucketBytes < symbolBytes) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          continue;
        }

        // Pick the next incomplete generation with headroom under its
        // debt cap: symbols sent since the last STATE beyond what could
        // plausibly finish it (missing rank x loss headroom + margin)
        // are feedback-lag waste, so rotate away.
        var picked = -1;
        for (var step = 0; step < generations; step++) {
          final g = (rotor + step) % generations;
          if (completed[g]) continue;
          final missing = genSize(g) - ranks[g];
          if (missing <= 0) continue;
          final debtCap = (missing * headroom).ceil() + 2;
          if (sentSinceState[g] >= debtCap) continue;
          picked = g;
          break;
        }
        if (picked < 0) {
          // Every incomplete generation is at its debt cap: wait for the
          // next STATE instead of pouring waste into the lag window.
          //
          // TERMINAL-CONFIRMATION SOLICIT (2026-08-10, msg-loss60 repro):
          // a SMALL transfer can deadlock exactly here. The receiver
          // completes, its single DONE is lost, its beacon stops (the
          // transfer left the active set), and this parked sender emits
          // nothing the completed-id re-answer path could respond to.
          // Measured on the Mac relay probe: sent=31, receiver's DONE
          // dropped, STATE silent 30 s, staleAfter abort — a ~0.6^3
          // chance per small transfer at 60% loss, invisible on 4 MiB
          // rows whose 128 generations keep frames flowing to the end.
          // While parked AND STATE-starved, keep ONE tiny frame flowing:
          // re-HELLO at stateInterval pace. An active receiver answers
          // with a fresh STATE; a completed receiver re-answers DONE.
          // Either response un-parks the loop the moment the reverse
          // path yields a survivor.
          final now = DateTime.now();
          if (now.difference(lastStateAt) > stateInterval * 3 &&
              now.difference(lastSolicitAt) >= stateInterval) {
            lastSolicitAt = now;
            await _port.send(hello);
          }
          await Future<void>.delayed(const Duration(milliseconds: 40));
          continue;
        }
        rotor = (picked + 1) % generations;

        final g = picked;
        final size = genSize(g);
        final Uint8List payload;
        final int seq;
        if (ranks[g] == 0 && systematicSent[g] < size) {
          // Systematic pass: free pivots for every survivor. Skipped
          // entirely once the generation has partial rank (see header).
          seq = systematicSent[g]++;
          payload = symbolAt(g * generationSize + seq);
        } else {
          seq = size + seqOffset + repairSeq[g]++;
          final coeffs = _coefficientsFor(g, seq, size);
          payload = Uint8List(symbolBytes);
          for (var i = 0; i < size; i++) {
            _Gf.addScaled(payload, symbolAt(g * generationSize + i), coeffs[i]);
          }
        }
        sentSinceState[g]++;
        sentSymbols++;
        bucketBytes -= symbolBytes;
        await _port.send(
          _FountainFrame(_typeSymbol, transferId, g, seq, payload).encode(),
        );
        // Yield to the EVENT queue (not just microtasks) every symbol:
        // over a synchronous in-process port the send loop otherwise
        // starves every Timer in the isolate — including the peer
        // receiver's STATE beacon.
        await Future<void>.delayed(Duration.zero);
      }
      return FountainSendResult(
        resumedGenerations: resumedGenerations,
        totalGenerations: generations,
        sentSymbols: sentSymbols,
        totalSourceSymbols: totalSymbols,
      );
    } finally {
      unawaited(sub.cancel());
    }
  }
}

class _RxGeneration {
  _RxGeneration(this.size, this.symbolBytes)
    : coeffRows = List<Uint8List?>.filled(size, null),
      dataRows = List<Uint8List?>.filled(size, null);

  final int size;
  final int symbolBytes;

  /// Row i, when present, is normalized with leading coefficient 1 at
  /// pivot column i (reduced incrementally on arrival).
  final List<Uint8List?> coeffRows;
  final List<Uint8List?> dataRows;
  int rank = 0;
  bool complete = false;
  List<Uint8List>? decoded;

  /// Incremental elimination; returns true when the symbol was innovative.
  bool offer(Uint8List coeffs, Uint8List data) {
    if (complete) return false;
    final c = Uint8List.fromList(coeffs);
    final d = Uint8List.fromList(data);
    for (var col = 0; col < size; col++) {
      if (c[col] == 0) continue;
      final pivot = coeffRows[col];
      if (pivot == null) {
        final invLead = _Gf.inv[c[col]];
        _Gf.scale(c, invLead);
        _Gf.scale(d, invLead);
        coeffRows[col] = c;
        dataRows[col] = d;
        rank++;
        if (rank == size) _solve();
        return true;
      }
      final lead = c[col];
      _Gf.addScaled(c, pivot, lead);
      _Gf.addScaled(d, dataRows[col]!, lead);
    }
    return false;
  }

  void _solve() {
    // Back-substitution over the echelon rows, highest pivot first.
    for (var col = size - 1; col >= 0; col--) {
      final row = coeffRows[col]!;
      final data = dataRows[col]!;
      for (var upper = 0; upper < col; upper++) {
        final factor = coeffRows[upper]![col];
        if (factor != 0) {
          _Gf.addScaled(coeffRows[upper]!, row, factor);
          _Gf.addScaled(dataRows[upper]!, data, factor);
        }
      }
    }
    decoded = [for (var i = 0; i < size; i++) dataRows[i]!];
    complete = true;
  }
}

class _RxTransfer {
  _RxTransfer(this.sizeBytes, this.symbolBytes, this.generationSize)
    : totalSymbols = (sizeBytes / symbolBytes).ceil().clamp(1, 1 << 31) {
    generations = [
      for (
        var g = 0;
        g < ((totalSymbols + generationSize - 1) ~/ generationSize);
        g++
      )
        _RxGeneration(
          (totalSymbols - g * generationSize) < generationSize
              ? totalSymbols - g * generationSize
              : generationSize,
          symbolBytes,
        ),
    ];
  }

  final int sizeBytes;
  final int symbolBytes;
  final int generationSize;
  final int totalSymbols;
  late final List<_RxGeneration> generations;

  int get cumulativeDecoded =>
      generations.fold(0, (a, g) => a + (g.complete ? g.size : g.rank));

  bool get allComplete => generations.every((g) => g.complete);

  Uint8List assemble() {
    final builder = BytesBuilder(copy: false);
    for (final g in generations) {
      for (final row in g.decoded!) {
        builder.add(row);
      }
    }
    final all = builder.toBytes();
    return Uint8List.sublistView(all, 0, sizeBytes);
  }
}

/// Receives fountain transfers; the mirror of [FountainStreamSender].
class FountainStreamReceiver {
  FountainStreamReceiver(
    this._port, {
    this.stateInterval = const Duration(milliseconds: 500),
    this.expireAfter = const Duration(seconds: 90),
    void Function(Uint8List content)? onCompleted,
  }) : _onCompleted = onCompleted {
    _sub = _port.inbound.listen(
      (raw) => unawaited(_onFrame(raw).catchError((Object _) {})),
    );
    _stateTimer = Timer.periodic(stateInterval, (_) {
      final now = DateTime.now();
      _active.removeWhere((key, _) {
        final seen = _lastActivity[key];
        final expired = seen != null && now.difference(seen) > expireAfter;
        if (expired) {
          _lastActivity.remove(key);
          _idOf.remove(key);
        }
        return expired;
      });
      for (final entry in _active.entries) {
        unawaited(_sendState(entry.key, entry.value));
      }
    });
  }

  final DataChannelPort _port;
  final Duration stateInterval;
  final void Function(Uint8List content)? _onCompleted;

  final Map<String, _RxTransfer> _active = {};
  final Map<String, Uint8List> _idOf = {};
  final Set<String> _completedIds = {};
  static const int _maxCompletedIds = 64;

  late final StreamSubscription<List<int>> _sub;
  late final Timer _stateTimer;
  final Map<String, DateTime> _lastActivity = {};

  /// Idle transfers are dropped (decode matrices are ~0.5 MB per
  /// generation) and their STATE beacon stops — a dead sender must not
  /// leak memory forever (review M3). CONSTRUCTOR-SET because the default
  /// deadlocks long outages: after expiry a re-registered receiver starts
  /// EMPTY while the sender's completed-generation flags only ever rise
  /// (applyState is monotone by design), so dropped state is unrecoverable
  /// within a transfer. A binding site whose recovery windows can exceed
  /// 90 s (the T2 rig budgets loss60 recoveries up to 220 s) must pass an
  /// [expireAfter] >= the sender's staleAfter so the sender's terminal
  /// condition, not silent state loss, ends a dead transfer.
  final Duration expireAfter;

  Future<void> _sendState(String key, _RxTransfer rx) async {
    final id = _idOf[key];
    if (id == null) return;
    final genCount = rx.generations.length;
    final bitmapBytes = (genCount + 7) >> 3;
    final payload = Uint8List(bitmapBytes + genCount);
    for (var g = 0; g < genCount; g++) {
      final gen = rx.generations[g];
      if (gen.complete) payload[g >> 3] |= 1 << (g & 7);
      payload[bitmapBytes + g] = gen.complete ? gen.size : gen.rank;
    }
    try {
      await _port.send(
        _FountainFrame(
          _typeState,
          id,
          rx.cumulativeDecoded,
          genCount,
          payload,
        ).encode(),
      );
    } catch (_) {}
  }

  Future<void> _onFrame(List<int> raw) async {
    final frame = _FountainFrame.tryDecode(raw);
    if (frame == null) return;
    final key = _idKey(frame.transferId);
    _lastActivity[key] = DateTime.now();
    if (_completedIds.contains(key)) {
      try {
        await _port.send(
          _FountainFrame(
            _typeDone,
            frame.transferId,
            0,
            0,
            Uint8List(0),
          ).encode(),
        );
      } catch (_) {}
      return;
    }
    switch (frame.type) {
      case _typeHello:
        // Geometry validation (review M2): a malformed or hostile HELLO
        // must be dropped, never divide by zero, allocate unbounded
        // state, or throw out of the listener.
        if (frame.payload.length < 8) return;
        if (frame.a < 1 || frame.a > (1 << 20)) return;
        if (frame.b < 1 || frame.b > 255) return;
        final size = ByteData.view(
          frame.payload.buffer,
          frame.payload.offsetInBytes,
        ).getUint64(0);
        if (size < 0 || size > (1 << 31)) return;
        final rx = _active.putIfAbsent(
          key,
          () => _RxTransfer(size, frame.a, frame.b),
        );
        _idOf[key] = Uint8List.fromList(frame.transferId);
        await _sendState(key, rx);
      case _typeSymbol:
        final rx = _active[key];
        if (rx == null) return;
        if (frame.a >= rx.generations.length) return;
        final gen = rx.generations[frame.a];
        if (gen.complete) return;
        final Uint8List coeffs;
        if (frame.b < gen.size) {
          coeffs = Uint8List(gen.size)..[frame.b] = 1;
        } else {
          coeffs = _coefficientsFor(frame.a, frame.b, gen.size);
        }
        // Own aligned copy: the inbound frame buffer is transient.
        final innovative = gen.offer(coeffs, Uint8List.fromList(frame.payload));
        if (innovative && rx.allComplete) {
          final content = rx.assemble();
          final digest = sha256.convert(content).bytes;
          var matches = content.length == rx.sizeBytes;
          final id = _idOf[key]!;
          for (var i = 0; i < 16 && matches; i++) {
            if (digest[i] != id[i]) matches = false;
          }
          if (matches) {
            _active.remove(key);
            _completedIds.add(key);
            while (_completedIds.length > _maxCompletedIds) {
              _completedIds.remove(_completedIds.first);
            }
            // Verified content reaches the caller BEFORE any network
            // write: a throwing DONE send must never orphan a decoded
            // transfer (review H4).
            _onCompleted?.call(content);
            try {
              await _port.send(
                _FountainFrame(_typeDone, id, 0, 0, Uint8List(0)).encode(),
              );
            } catch (_) {}
          }
        }
      case _typeState:
      case _typeDone:
        return;
    }
  }

  Future<void> dispose() async {
    _stateTimer.cancel();
    await _sub.cancel();
  }
}
