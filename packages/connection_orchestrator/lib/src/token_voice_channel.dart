/// Half-live token voice over an intermittent link ("water-drop call"):
/// hamseda-coded token blocks ride the durable DTN queue, so the
/// conversation keeps flowing on a link that only breathes for a few
/// seconds at a time.
///
/// Protocol invariants:
/// - blocks are chain-encoded (each against the state after the previous
///   one) and carry an (epoch, seq) header; the receiver replays them
///   strictly in order through a reorder buffer, so codec state on both
///   ends stays byte-identical no matter how delivery interleaves;
/// - a failed flush attempt leaves the bundle in the durable queue (the
///   queue's existing contract) — nothing is lost mid-pulse;
/// - if a block's lifetime expires undelivered, the chain is broken:
///   the sender bumps the EPOCH and restarts from a fresh codec state;
///   the receiver drops buffered stale-epoch blocks and follows. The
///   dictionary warmth of the old epoch is lost, correctness is not.
library;

import 'dart:typed_data';

import 'package:device_link/device_link.dart';
import 'package:hamseda_codec/hamseda_codec.dart';

/// Sender side: encodes token-column blocks into DTN bundles.
class TokenVoiceSender {
  TokenVoiceSender({
    required this.nRows,
    required this.queue,
    this.blockLifetime = const Duration(seconds: 30),
    HamsedaState? initialState,
  }) : _state = initialState ?? HamsedaState(nRows);

  final int nRows;
  final DtnBundleQueue queue;
  final Duration blockLifetime;

  HamsedaState _state;
  int _epoch = 0;
  int _seq = 0;

  /// Blocks whose lifetime expired before delivery (epoch restarts).
  int epochRestarts = 0;

  int get epoch => _epoch;

  /// The current codec state — persist its JSON per contact between
  /// calls to keep the dictionary warm (the cross-call record lever).
  HamsedaState get state => _state;

  /// Encodes [columns] as the next chained block and offers it to the
  /// durable queue. Returns the bundle id.
  String sendBlock(List<List<int>> columns, {required int nowMs}) {
    // A block that expired undelivered breaks the receiver's chain:
    // restart the epoch BEFORE encoding, from a fresh state.
    if (queue.purgeExpired(nowMs) > 0) {
      _epoch += 1;
      _seq = 0;
      _state = HamsedaState(nRows);
      epochRestarts += 1;
    }
    final data = encodeColumns(columns, _state);
    final header = ByteData(6)
      ..setUint16(0, _epoch)
      ..setUint16(2, _seq)
      ..setUint16(4, columns.length);
    final id = 'token-voice-$_epoch-$_seq';
    queue.offer(
      DtnBundle(
        id: id,
        payload: [...header.buffer.asUint8List(), ...data],
        priority: MeshMessagePriority.callSignal,
        createdAtMs: nowMs,
        lifetimeMs: blockLifetime.inMilliseconds,
      ),
      nowMs: nowMs,
    );
    _seq += 1;
    return id;
  }
}

/// Receiver side: reorders delivered blocks and replays them in order.
class TokenVoiceReceiver {
  TokenVoiceReceiver({required this.nRows, HamsedaState? initialState})
      : _state = initialState ?? HamsedaState(nRows);

  final int nRows;

  /// The current codec state (persist per contact between calls).
  HamsedaState get state => _state;

  HamsedaState _state;
  int _epoch = 0;
  int _nextSeq = 0;
  final Map<int, Uint8List> _buffer = {};

  /// Stale-epoch blocks dropped after an epoch restart.
  int staleDropped = 0;

  /// Decoded blocks in playback order, appended as they become ready.
  final List<List<List<int>>> played = [];

  int get epoch => _epoch;

  /// Offer one delivered bundle payload; decodes every block that is now
  /// in sequence and returns the newly playable blocks.
  List<List<List<int>>> offer(List<int> payload) {
    final bytes = Uint8List.fromList(payload);
    final header = ByteData.sublistView(bytes, 0, 6);
    final epoch = header.getUint16(0);
    final seq = header.getUint16(2);
    if (epoch < _epoch) {
      staleDropped += 1;
      return const [];
    }
    if (epoch > _epoch) {
      // Sender restarted the chain: follow it, drop the stale buffer.
      staleDropped += _buffer.length;
      _buffer.clear();
      _epoch = epoch;
      _nextSeq = 0;
      _state = HamsedaState(nRows);
    }
    _buffer[seq] = bytes;
    final ready = <List<List<int>>>[];
    while (_buffer.containsKey(_nextSeq)) {
      final b = _buffer.remove(_nextSeq)!;
      final nFrames = ByteData.sublistView(b, 0, 6).getUint16(4);
      final cols =
          decodeColumns(Uint8List.sublistView(b, 6), nFrames, _state);
      ready.add(cols);
      played.add(cols);
      _nextSeq += 1;
    }
    return ready;
  }

  /// Exposes the codec state fingerprint for divergence checks in tests.
  String stateFingerprint() => _state.toJson().toString();
}
