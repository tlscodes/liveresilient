/// Many rateless symbols in one padded frame, so the privacy pad is paid once.
///
/// THE MEASUREMENT THAT FORCED THIS (Run I). A 60-byte RLNC datagram costs
/// 218.6 bytes mean on the wire — x3.64 — because `MicroDatagramLane` adds a
/// random base pad plus **0..3 WHOLE BLOCKS** of anti-fingerprinting jitter. At
/// the default block size of 64 that is up to 192 bytes of deliberate noise on
/// a 60-byte payload. The padding is not a defect; it is a real defence and it
/// works as written. The defect is that its cost is ABSOLUTE while the
/// cliff-free datagram is tiny: 192 bytes is 14% of a 1,400-byte frame and 320%
/// of a 60-byte one.
///
/// Meanwhile every byte figure in CLIFF-FREE-CODING §14 and CLIFF-FREE-VIDEO
/// §15 — the framing floor, the redundancy law, the rung ladder's N_bytes — is
/// computed on the 60 bytes. So the design's arithmetic and the wire disagreed
/// by a factor nobody had measured, because nothing had ever put a cliff-free
/// datagram through the carrier.
///
/// Batching pays the pad once per FRAME instead of once per SYMBOL. The privacy
/// property is untouched: frame sizes are still jittered by the same lane, an
/// observer still cannot read payload length off the wire, and no parameter of
/// the padding changes. Only the number of times it is paid changes.
///
/// WHAT IT COSTS, AND WHY THE COST IS MEASURED RATHER THAN ASSUMED. Batching
/// converts independent symbol loss into BURST loss: one dropped frame takes
/// every symbol inside it. Rateless coding is indifferent to *which* symbols
/// arrive — only the count matters — so the first-order effect is nil. The
/// second-order effect is not: burst loss raises the VARIANCE of delivered
/// rank, and the Gilbert-Elliott estimator infers channel state from esi gaps
/// that batching makes coarser. Neither is assumed here.
/// `cliff_free_batch_test.dart` measures both.
///
/// ADDRESSING MOVES IN-BAND, AND TWO DEFECTS CLOSE WITH IT.
///
/// The old scheme put (objectId · layerCount · layerIndex) in a 32-bit transfer
/// id and nothing in the datagram. `MediaCarriage.maxTransferId` is 0xFFFF, so
/// it rejected every object past the first (Run I-2), and `MediaType` was never
/// transmitted at all, leaving the receiver to invent the value that decides
/// how the object renders (Run I-3).
///
/// A batch header costs 9 bytes ONCE PER FRAME rather than per symbol, so
/// carrying the full address in-band is affordable in a way it never was
/// per-datagram. `objectId` stays available as the carriage transfer id for
/// routing — and 16 bits is exactly what a u16 objectId needs, so the carrier's
/// limit stops being a limit. The frame is self-describing regardless: a
/// receiver that has only the bytes can recover the whole address.
library;

import 'dart:typed_data';

import 'resilient_media_transport.dart' show MediaType;

/// Why a batch could not be decoded. Every rejection is counted and named:
/// silent drops on a lossy link are indistinguishable from the link, which is
/// the one confusion this project can least afford.
enum CliffFreeBatchError {
  /// Not a batch frame at all (wrong magic, or too short to hold a header).
  notABatch,

  /// A version this build does not implement.
  unsupportedVersion,

  /// Header parsed, but the declared sizes do not match the byte count.
  lengthMismatch,

  /// Header parsed and sized correctly, but a field is impossible
  /// (zero symbols, layerIndex outside layerCount, symbol size out of range).
  malformedHeader,
}

class CliffFreeBatchException implements Exception {
  const CliffFreeBatchException(this.error, this.detail);
  final CliffFreeBatchError error;
  final String detail;

  @override
  String toString() => 'CliffFreeBatchException(${error.name}: $detail)';
}

/// One decoded batch: an address plus the symbols that share it.
class CliffFreeBatch {
  const CliffFreeBatch({
    required this.objectId,
    required this.type,
    required this.layerCount,
    required this.layerIndex,
    required this.symbols,
  });

  final int objectId;
  final MediaType type;
  final int layerCount;
  final int layerIndex;

  /// Views into the frame, not copies. The frame outlives the batch in every
  /// current caller, and copying 60 bytes per symbol on the receive path of a
  /// device that is already short of bandwidth buys nothing.
  final List<Uint8List> symbols;

  @override
  String toString() =>
      'CliffFreeBatch(object $objectId, layer $layerIndex/$layerCount, '
      '${symbols.length} symbols, ${type.name})';
}

/// The frame format, encoder and decoder.
///
/// ```
/// offset size field
/// 0      1    magic 0xCF
/// 1      1    version (1)
/// 2      2    objectId          u16 big-endian
/// 4      1    mediaType index
/// 5      1    layerCount        1..255
/// 6      1    layerIndex        0..layerCount-1
/// 7      1    symbolCount       1..255
/// 8      1    symbolBytes       36..60  (fits one byte; see the check below)
/// 9      ...  symbolCount * symbolBytes
/// ```
///
/// SYMBOL SIZE IS ONE BYTE, NOT TWO, and that is a claim about the encoder
/// rather than a guess. `RlncEncoder` refuses any block size outside 31..55,
/// and a datagram is `4 + blockSize + 1`, so the only sizes that can ever
/// appear are 36..60. A u16 field would spend a byte per frame to express
/// values the producer cannot produce.
class CliffFreeBatchCodec {
  const CliffFreeBatchCodec._();

  static const int magic = 0xCF;
  static const int version = 1;
  static const int headerBytes = 9;

  /// Smallest and largest datagram `RlncEncoder` can emit (blockSize 31..55).
  static const int minSymbolBytes = 36;
  static const int maxSymbolBytes = 60;

  /// Most symbols one frame may carry.
  ///
  /// 255 is the field's limit; the useful limit is lower and is the caller's
  /// choice. At 60 bytes a symbol, 255 symbols is a 15 KB frame, which on the
  /// 16 Kbit/s `narrow` profile is seven and a half seconds of link time in a
  /// single loseable unit. Batching trades pad for burst, and past some size
  /// the trade stops being good — see the measured table in the tests.
  static const int maxSymbols = 255;

  static Uint8List encode({
    required int objectId,
    required MediaType type,
    required int layerCount,
    required int layerIndex,
    required List<Uint8List> symbols,
  }) {
    if (objectId < 0 || objectId > 0xFFFF) {
      throw ArgumentError.value(objectId, 'objectId', 'must fit u16');
    }
    if (layerCount < 1 || layerCount > 0xFF) {
      throw ArgumentError.value(layerCount, 'layerCount', 'must be 1..255');
    }
    if (layerIndex < 0 || layerIndex >= layerCount) {
      throw ArgumentError.value(
        layerIndex,
        'layerIndex',
        'must be 0..${layerCount - 1}',
      );
    }
    if (symbols.isEmpty || symbols.length > maxSymbols) {
      throw ArgumentError.value(
        symbols.length,
        'symbols',
        'must be 1..$maxSymbols',
      );
    }

    final size = symbols.first.length;
    if (size < minSymbolBytes || size > maxSymbolBytes) {
      throw ArgumentError.value(
        size,
        'symbols[0].length',
        'must be $minSymbolBytes..$maxSymbolBytes',
      );
    }
    // RAGGED BATCHES ARE REFUSED, NOT PADDED. One size per frame is what makes
    // the header nine bytes instead of nine plus a length per symbol. A caller
    // that mixes block sizes inside one object has a bug upstream, and padding
    // the short ones here would hide it behind symbols the decoder then treats
    // as corrupt — a CRC failure attributed to the network.
    for (var i = 1; i < symbols.length; i++) {
      if (symbols[i].length != size) {
        throw ArgumentError(
          'symbol $i is ${symbols[i].length} B but symbol 0 is $size B: '
          'one frame carries one symbol size',
        );
      }
    }

    final frame = Uint8List(headerBytes + symbols.length * size);
    frame[0] = magic;
    frame[1] = version;
    frame[2] = (objectId >> 8) & 0xFF;
    frame[3] = objectId & 0xFF;
    frame[4] = type.index;
    frame[5] = layerCount;
    frame[6] = layerIndex;
    frame[7] = symbols.length;
    frame[8] = size;
    var at = headerBytes;
    for (final s in symbols) {
      frame.setRange(at, at + size, s);
      at += size;
    }
    return frame;
  }

  /// Throws [CliffFreeBatchException] rather than returning null.
  ///
  /// The caller must distinguish "this frame is not ours" from "this frame is
  /// ours and is broken": the first is normal on a shared lane, the second is
  /// either an attack or a bug, and a null return collapses them into one
  /// silent path. [tryDecode] exists for the callers that genuinely only want
  /// the first question answered.
  static CliffFreeBatch decode(Uint8List frame) {
    if (frame.length < headerBytes) {
      throw CliffFreeBatchException(
        CliffFreeBatchError.notABatch,
        'only ${frame.length} B, header is $headerBytes B',
      );
    }
    if (frame[0] != magic) {
      throw CliffFreeBatchException(
        CliffFreeBatchError.notABatch,
        'magic 0x${frame[0].toRadixString(16)}',
      );
    }
    if (frame[1] != version) {
      throw CliffFreeBatchException(
        CliffFreeBatchError.unsupportedVersion,
        'version ${frame[1]}, this build speaks $version',
      );
    }

    final objectId = (frame[2] << 8) | frame[3];
    final typeIndex = frame[4];
    final layerCount = frame[5];
    final layerIndex = frame[6];
    final symbolCount = frame[7];
    final symbolBytes = frame[8];

    // A media type index off the end of the enum is remotely triggerable, and
    // `MediaType.values[i]` on it throws RangeError out of a receive path.
    if (typeIndex >= MediaType.values.length) {
      throw CliffFreeBatchException(
        CliffFreeBatchError.malformedHeader,
        'media type index $typeIndex is not a MediaType',
      );
    }
    if (layerCount < 1 || layerIndex >= layerCount) {
      throw CliffFreeBatchException(
        CliffFreeBatchError.malformedHeader,
        'layer $layerIndex of $layerCount',
      );
    }
    if (symbolCount < 1) {
      throw const CliffFreeBatchException(
        CliffFreeBatchError.malformedHeader,
        'a batch with no symbols carries nothing',
      );
    }
    if (symbolBytes < minSymbolBytes || symbolBytes > maxSymbolBytes) {
      throw CliffFreeBatchException(
        CliffFreeBatchError.malformedHeader,
        'symbol size $symbolBytes outside $minSymbolBytes..$maxSymbolBytes',
      );
    }

    final expected = headerBytes + symbolCount * symbolBytes;
    if (frame.length != expected) {
      throw CliffFreeBatchException(
        CliffFreeBatchError.lengthMismatch,
        'header declares $expected B, frame is ${frame.length} B',
      );
    }

    final symbols = <Uint8List>[];
    for (var i = 0; i < symbolCount; i++) {
      final start = headerBytes + i * symbolBytes;
      symbols.add(Uint8List.sublistView(frame, start, start + symbolBytes));
    }

    return CliffFreeBatch(
      objectId: objectId,
      type: MediaType.values[typeIndex],
      layerCount: layerCount,
      layerIndex: layerIndex,
      symbols: symbols,
    );
  }

  /// Null when [frame] is not a batch at all; still throws when it IS a batch
  /// and is malformed. A frame that claims our magic and then lies about its
  /// own length is not "someone else's traffic".
  static CliffFreeBatch? tryDecode(Uint8List frame) {
    try {
      return decode(frame);
    } on CliffFreeBatchException catch (e) {
      if (e.error == CliffFreeBatchError.notABatch) return null;
      rethrow;
    }
  }
}

/// Accumulates symbols and emits a frame when the batch is full or the address
/// changes.
///
/// ONE ADDRESS PER FRAME is the reason this class exists rather than a bare
/// `encode` call. The sender emits layer by layer, so a naive fixed-size
/// batcher would straddle a layer boundary and have no single header to
/// describe its contents. Flushing on address change costs one short frame per
/// layer and keeps the header at nine bytes.
class CliffFreeBatcher {
  CliffFreeBatcher({
    required this.objectId,
    required this.type,
    required this.layerCount,
    this.maxSymbolsPerFrame = 10,
  }) {
    if (maxSymbolsPerFrame < 1 ||
        maxSymbolsPerFrame > CliffFreeBatchCodec.maxSymbols) {
      throw ArgumentError.value(
        maxSymbolsPerFrame,
        'maxSymbolsPerFrame',
        'must be 1..${CliffFreeBatchCodec.maxSymbols}',
      );
    }
  }

  final int objectId;
  final MediaType type;
  final int layerCount;

  /// Ten by default: the pad has amortized from x3.78 to x1.24, and a frame
  /// is 706 B, which is 0.35 s even on the 16 Kbit/s `narrow` profile — inside
  /// the 0.5 s head budget with room for the worst-case pad.
  ///
  /// It is a fallback for callers that do not know their link rate, not a
  /// recommendation. A caller that does know should use [forLink], because the
  /// right answer moves by an order of magnitude between 16 Kbit/s and Wi-Fi.
  final int maxSymbolsPerFrame;

  /// The largest batch whose frame still reaches the peer inside
  /// [headBudget] at [bytesPerSecond].
  ///
  /// LOSS DOES NOT BOUND THE BATCH SIZE, AND THE MEASUREMENT IS WHY.
  ///
  /// The first policy written here was a ladder that shrank the batch as loss
  /// rose, reasoning that burst loss hurts more on a bad link. Both halves of
  /// that reasoning are true and the conclusion was still wrong. Measured
  /// (`cliff_free_batch_test.dart`), wire bytes per SUCCESSFULLY DELIVERED
  /// 3 KB object, redundancy provisioned at the measured law 1.2/(1-p):
  ///
  /// ```
  ///   loss |   N=1     N=2     N=4    N=10    N=20     best
  ///      5% | 19865   12713    8983    6553    6130     N=20
  ///     20% | 19888   12818    9345    7458    7238     N=20
  ///     40% | 58736   36017   21248   16170   10998     N=20
  /// ```
  ///
  /// Bigger is cheaper at EVERY loss level, including 40%. The pad on a small
  /// frame (x3.85) costs more than the bursts ever do. Batching does convert
  /// independent loss into burst loss — that cost is real and separately
  /// measured at -23 points of decode success at 30% loss for N=10 — and it is
  /// simply smaller than the padding it removes.
  ///
  /// So something else has to stop N from growing, and it is not bytes. It is
  /// TIME. A frame is atomic: nothing inside it decodes until all of it has
  /// arrived. The cliff-free path exists to put a base layer on screen early,
  /// and on the 16 Kbit/s `narrow` profile — 2,000 B/s — an N=80 frame is
  /// 4,964 bytes, which is 2.5 seconds during which the receiver has nothing
  /// at all. That is the constraint, and it is the one this function encodes.
  ///
  /// [headBudget] defaults to the 0.5 s "first visual" figure from
  /// CLIFF-FREE-VIDEO §15. A caller sending a background document rather than
  /// a head layer should raise it and get bigger, cheaper frames.
  static int batchSizeForLinkRate({
    required double bytesPerSecond,
    Duration headBudget = const Duration(milliseconds: 500),
    int symbolBytes = CliffFreeBatchCodec.maxSymbolBytes,
  }) {
    // No usable rate is not evidence of a fast link — the same rule the media
    // router applies to a NaN loss estimate. Take the conservative end.
    if (bytesPerSecond.isNaN || bytesPerSecond.isInfinite ||
        bytesPerSecond <= 0) {
      return 2;
    }

    final budgetBytes = bytesPerSecond * headBudget.inMicroseconds / 1e6;

    // The wire cost is not the frame size: `MicroDatagramLane` adds a random
    // base pad, alignment, and 0..3 whole blocks of jitter. Budgeting against
    // the frame size would silently overrun by the padding factor — the exact
    // error this whole change exists to correct. Size against the WORST case,
    // because a budget that holds on average still misses half the time.
    const worstCasePadBytes = 32 + 64 + 3 * 64; // base + alignment + jitter
    const carrierBytes = 2;
    final usable = budgetBytes -
        CliffFreeBatchCodec.headerBytes -
        worstCasePadBytes -
        carrierBytes;
    if (usable < symbolBytes) return 1;

    final n = usable ~/ symbolBytes;
    // 20 is where the measured bytes-per-success curve has flattened (6,130 vs
    // 6,553 at N=10 — a further 6%), so growing past it buys little and costs
    // latency on every link. The cap is a measured stopping point, not a
    // round number.
    if (n > 20) return 20;
    return n;
  }

  /// A batcher sized for the link it is about to use.
  ///
  /// [lossEstimate] is accepted and deliberately NOT used to size the batch —
  /// see [batchSizeForLinkRate] for the measurement that removed it. It is
  /// kept in the signature because callers have it and the next person will
  /// otherwise re-derive the wrong policy from first principles, as this file
  /// did once already.
  factory CliffFreeBatcher.forLink({
    required int objectId,
    required MediaType type,
    required int layerCount,
    required double bytesPerSecond,
    Duration headBudget = const Duration(milliseconds: 500),
  }) => CliffFreeBatcher(
    objectId: objectId,
    type: type,
    layerCount: layerCount,
    maxSymbolsPerFrame: batchSizeForLinkRate(
      bytesPerSecond: bytesPerSecond,
      headBudget: headBudget,
    ),
  );

  final List<Uint8List> _pending = [];
  int? _layerIndex;

  /// Frames produced so far, for accounting.
  int framesEmitted = 0;
  int symbolsBatched = 0;

  /// Adds one symbol; returns a frame when one became ready, else null.
  Uint8List? add(int layerIndex, Uint8List symbol) {
    Uint8List? out;
    if (_layerIndex != null && layerIndex != _layerIndex) {
      out = flush();
    }
    _layerIndex = layerIndex;
    _pending.add(symbol);
    symbolsBatched++;
    if (_pending.length >= maxSymbolsPerFrame) {
      // A flush triggered by the address change AND a full batch in the same
      // call would drop the first frame on the floor if this overwrote it.
      // Returning the address-change frame and keeping the full batch pending
      // is the only order that loses nothing; the caller gets the second frame
      // on the next add or at close.
      out ??= flush();
    }
    return out;
  }

  /// Emits whatever is pending, or null if nothing is.
  Uint8List? flush() {
    if (_pending.isEmpty) return null;
    final frame = CliffFreeBatchCodec.encode(
      objectId: objectId,
      type: type,
      layerCount: layerCount,
      layerIndex: _layerIndex!,
      symbols: List.of(_pending),
    );
    _pending.clear();
    framesEmitted++;
    return frame;
  }

  /// Symbols waiting for a frame. Nonzero at the end of a send means the
  /// caller forgot to [flush], which loses real data rather than merely
  /// delaying it.
  int get pendingSymbols => _pending.length;
}
