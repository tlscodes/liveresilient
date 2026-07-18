import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';

/// Packet timestamps must use milliseconds.
///
/// [senderTimestampMs] is expected to be a sender-relative monotonic media
/// timestamp, not necessarily a Unix wall-clock timestamp.
///
/// [arrivalMs] passed to [AdaptiveJitterBuffer.addPacket] must come from a
/// receiver-side monotonic clock.
class MediaPacket {
  final int sequenceNumber;
  final int senderTimestampMs;
  final Uint8List payload;

  MediaPacket({
    required this.sequenceNumber,
    required this.senderTimestampMs,
    required List<int> payload,
  }) : payload = Uint8List.fromList(payload) {
    if (sequenceNumber < 0 || sequenceNumber > 0xffff) {
      throw RangeError.range(sequenceNumber, 0, 0xffff, 'sequenceNumber');
    }
  }
}

class _QueuedPacket {
  final int extendedSequence;
  final int arrivalMs;
  final MediaPacket packet;

  const _QueuedPacket({
    required this.extendedSequence,
    required this.arrivalMs,
    required this.packet,
  });
}

/// Adaptive inter-arrival jitter buffer for non-WebRTC datagrams.
///
/// For live WebRTC audio/video, use WebRTC's native jitter buffer instead.
///
/// A sender-timestamp discontinuity (renegotiation, sender restart, or any
/// event that resets [MediaPacket.senderTimestampMs] to a new base) is not
/// detected automatically: the caller must call [clear] when it knows such
/// a discontinuity occurred, otherwise `targetDelayMs`/`takeNext` scheduling
/// will be computed against a stale `_firstSenderTimestampMs` baseline.
class AdaptiveJitterBuffer {
  final int minimumDelayMs;
  final int maximumDelayMs;
  final int lateDropThresholdMs;
  final int maximumPackets;

  final SplayTreeMap<int, _QueuedPacket> _queue =
      SplayTreeMap<int, _QueuedPacket>();

  int? _highestExtendedSequence;
  int? _lastPlayedExtendedSequence;

  int? _firstArrivalMs;
  int? _firstSenderTimestampMs;

  int? _lastTimingArrivalMs;
  int? _lastTimingSenderTimestampMs;
  int? _lastTimingExtendedSequence;

  double _estimatedJitterMs = 0;

  int droppedDuplicates = 0;
  int droppedLate = 0;
  int droppedOverflow = 0;

  AdaptiveJitterBuffer({
    this.minimumDelayMs = 60,
    this.maximumDelayMs = 200,
    this.lateDropThresholdMs = 250,
    this.maximumPackets = 256,
  }) : assert(minimumDelayMs >= 0),
       assert(maximumDelayMs >= minimumDelayMs),
       assert(lateDropThresholdMs >= 0),
       assert(maximumPackets > 0);

  int get bufferedPacketCount => _queue.length;

  double get estimatedJitterMs => _estimatedJitterMs;

  int get targetDelayMs {
    final target = minimumDelayMs + (4 * _estimatedJitterMs);
    return target.clamp(minimumDelayMs, maximumDelayMs).round();
  }

  /// Returns false when the packet is an old or duplicate packet.
  bool addPacket(MediaPacket packet, {required int arrivalMs}) {
    if (_lastTimingArrivalMs != null && arrivalMs < _lastTimingArrivalMs!) {
      throw ArgumentError.value(
        arrivalMs,
        'arrivalMs',
        'Arrival timestamps must come from a monotonic clock.',
      );
    }

    final extendedSequence = _extendSequence(packet.sequenceNumber);

    if (_lastPlayedExtendedSequence != null &&
        extendedSequence <= _lastPlayedExtendedSequence!) {
      droppedLate++;
      return false;
    }

    if (_queue.containsKey(extendedSequence)) {
      droppedDuplicates++;
      return false;
    }

    _firstArrivalMs ??= arrivalMs;
    _firstSenderTimestampMs ??= packet.senderTimestampMs;

    // Update timing only with a packet newer than the last timing sample.
    // This prevents a reordered packet from creating an artificial jitter
    // spike.
    if (_lastTimingExtendedSequence == null ||
        extendedSequence > _lastTimingExtendedSequence!) {
      if (_lastTimingArrivalMs != null &&
          _lastTimingSenderTimestampMs != null) {
        final arrivalDelta = arrivalMs - _lastTimingArrivalMs!;
        final senderDelta =
            packet.senderTimestampMs - _lastTimingSenderTimestampMs!;

        final variation = (arrivalDelta - senderDelta).abs().toDouble();

        // RFC 3550-style EWMA:
        // J(i) = J(i-1) + (D(i) - J(i-1)) / 16
        _estimatedJitterMs += (variation - _estimatedJitterMs) / 16.0;
      }

      _lastTimingArrivalMs = arrivalMs;
      _lastTimingSenderTimestampMs = packet.senderTimestampMs;
      _lastTimingExtendedSequence = extendedSequence;
    }

    _queue[extendedSequence] = _QueuedPacket(
      extendedSequence: extendedSequence,
      arrivalMs: arrivalMs,
      packet: packet,
    );

    while (_queue.length > maximumPackets) {
      final first = _queue.entries.first;
      _queue.remove(first.key);
      droppedOverflow++;
    }

    return true;
  }

  /// Returns the next playable packet or null when more buffering is needed.
  MediaPacket? takeNext({required int nowMs}) {
    while (_queue.isNotEmpty) {
      final firstEntry = _queue.entries.first;
      final queued = firstEntry.value;

      final scheduledPlayoutMs =
          _firstArrivalMs! +
          (queued.packet.senderTimestampMs - _firstSenderTimestampMs!) +
          targetDelayMs;

      if (nowMs < scheduledPlayoutMs) {
        return null;
      }

      _queue.remove(firstEntry.key);

      if (_lastPlayedExtendedSequence != null &&
          queued.extendedSequence <= _lastPlayedExtendedSequence!) {
        droppedDuplicates++;
        continue;
      }

      if (nowMs - scheduledPlayoutMs > lateDropThresholdMs) {
        droppedLate++;
        _lastPlayedExtendedSequence = queued.extendedSequence;
        continue;
      }

      _lastPlayedExtendedSequence = queued.extendedSequence;
      return queued.packet;
    }

    return null;
  }

  void clear() {
    _queue.clear();
    _highestExtendedSequence = null;
    _lastPlayedExtendedSequence = null;
    _firstArrivalMs = null;
    _firstSenderTimestampMs = null;
    _lastTimingArrivalMs = null;
    _lastTimingSenderTimestampMs = null;
    _lastTimingExtendedSequence = null;
    _estimatedJitterMs = 0;
    droppedDuplicates = 0;
    droppedLate = 0;
    droppedOverflow = 0;
  }

  /// Converts a 16-bit RTP-like sequence number into an extended sequence.
  int _extendSequence(int sequence) {
    if (_highestExtendedSequence == null) {
      _highestExtendedSequence = sequence;
      return sequence;
    }

    final highest = _highestExtendedSequence!;
    final cycleBase = highest & ~0xffff;

    var candidate = cycleBase | sequence;

    if (candidate - highest > 0x8000) {
      candidate -= 0x10000;
    } else if (highest - candidate > 0x8000) {
      candidate += 0x10000;
    }

    if (candidate > highest) {
      _highestExtendedSequence = candidate;
    }

    return candidate;
  }
}

/// Metadata required to recover one missing data shard.
class XorFecBlock {
  final int blockId;
  final List<int> originalLengths;
  final Uint8List parity;

  XorFecBlock({
    required this.blockId,
    required List<int> originalLengths,
    required List<int> parity,
  }) : originalLengths = List<int>.unmodifiable(originalLengths),
       parity = Uint8List.fromList(parity) {
    if (blockId < 0) {
      throw ArgumentError.value(blockId, 'blockId');
    }
  }

  int get dataShardCount => originalLengths.length;

  int get maximumShardLength => originalLengths.fold<int>(0, math.max);
}

class RecoveredFecShard {
  final int index;
  final Uint8List data;

  RecoveredFecShard({required this.index, required List<int> data})
    : data = Uint8List.fromList(data);
}

/// XOR FEC can recover exactly one missing shard.
///
/// This class provides loss recovery, not authenticity. Shards must still be
/// covered by authenticated encryption or a verified MAC.
///
/// Static-members-only utility: never instantiated.
abstract final class XorFec {
  static XorFecBlock encode({
    required int blockId,
    required List<List<int>> packets,
  }) {
    if (packets.isEmpty) {
      throw ArgumentError.value(
        packets,
        'packets',
        'At least one data shard is required.',
      );
    }

    final originalLengths = packets
        .map((packet) => packet.length)
        .toList(growable: false);

    final maximumLength = originalLengths.fold<int>(0, math.max);

    final parity = Uint8List(maximumLength);

    for (final packet in packets) {
      for (var index = 0; index < packet.length; index++) {
        parity[index] ^= packet[index];
      }
    }

    return XorFecBlock(
      blockId: blockId,
      originalLengths: originalLengths,
      parity: parity,
    );
  }

  /// [receivedDataShards] must contain one entry per original data shard.
  ///
  /// Exactly one entry may be null. More than one missing shard cannot be
  /// recovered using single-parity XOR FEC.
  static RecoveredFecShard? recover({
    required XorFecBlock block,
    required List<Uint8List?> receivedDataShards,
    Uint8List? receivedParity,
  }) {
    if (receivedDataShards.length != block.dataShardCount) {
      throw ArgumentError.value(
        receivedDataShards.length,
        'receivedDataShards.length',
        'Expected ${block.dataShardCount} data shards.',
      );
    }

    final missing = <int>[];

    for (var index = 0; index < receivedDataShards.length; index++) {
      final shard = receivedDataShards[index];

      if (shard == null) {
        missing.add(index);
        continue;
      }

      if (shard.length != block.originalLengths[index]) {
        throw FormatException(
          'Shard $index has length ${shard.length}; '
          'expected ${block.originalLengths[index]}.',
        );
      }
    }

    if (missing.isEmpty || missing.length > 1) {
      return null;
    }

    final parity = receivedParity ?? block.parity;

    if (parity.length != block.maximumShardLength) {
      throw FormatException(
        'Parity length ${parity.length} does not match '
        '${block.maximumShardLength}.',
      );
    }

    final recovered = Uint8List.fromList(parity);

    for (final shard in receivedDataShards) {
      if (shard == null) {
        continue;
      }

      for (var index = 0; index < shard.length; index++) {
        recovered[index] ^= shard[index];
      }
    }

    final missingIndex = missing.single;
    final originalLength = block.originalLengths[missingIndex];

    return RecoveredFecShard(
      index: missingIndex,
      data: recovered.sublist(0, originalLength),
    );
  }
}
