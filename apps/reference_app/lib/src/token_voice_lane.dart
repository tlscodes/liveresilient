/// The live token-voice lane: while the call runs in
/// [DegradedMode.tokenVoice], microphone PCM flows through the device
/// codec binding into hamseda blocks on the durable queue, and delivered
/// blocks come back out as PCM for the speaker. Entering/leaving the
/// mode starts/stops the lane; the call object itself never changes.
///
/// Mic and speaker are SEAMS: production injects platform audio I/O,
/// tests inject synthetic PCM and capture the output.
library;

import 'dart:async';

import 'package:call_core/call_core.dart';
import 'package:connection_orchestrator/connection_orchestrator.dart';
import 'package:device_link/device_link.dart';

import 'degraded_mode_driver.dart' show DegradableCallHandle;

class TokenVoiceLane {
  TokenVoiceLane({
    required DegradableCallHandle call,
    required this.codec,
    required this.queue,
    required Stream<List<double>> microphone,
    required this.speaker,
    this.framesPerBlock = 25,
    this.flushEvery = const Duration(seconds: 1),
  }) {
    _stateSub = call.states.listen(_onState);
    _micSub = microphone.listen(_onPcm);
  }

  final VoiceCodecBinding codec;
  final DtnBundleQueue queue;

  /// Where decoded far-end PCM goes (platform speaker in production).
  final void Function(List<double> pcm) speaker;

  final int framesPerBlock;
  final Duration flushEvery;

  late final StreamSubscription<CallState> _stateSub;
  late final StreamSubscription<List<double>> _micSub;
  Timer? _flushTimer;
  TokenVoiceSender? _sender;
  TokenVoiceReceiver? _receiver;
  final List<List<int>> _pendingColumns = [];
  bool _active = false;
  bool _disposed = false;

  /// Blocks sent / received (badges and tests).
  int blocksSent = 0;
  int blocksPlayed = 0;

  bool get active => _active;

  void _onState(CallState state) {
    if (_disposed) return;
    final wantActive = state.degradedMode == DegradedMode.tokenVoice;
    if (wantActive && !_active) {
      _start();
    } else if (!wantActive && _active) {
      _stop();
    }
  }

  Future<void> _start() async {
    if (!await codec.available) return; // ladder should prevent this
    final info = await codec.modelInfo;
    _sender = TokenVoiceSender(nRows: info.nRows, queue: queue);
    _receiver = TokenVoiceReceiver(nRows: info.nRows);
    _active = true;
    _flushTimer = Timer.periodic(flushEvery, (_) => _pump());
  }

  void _stop() {
    _active = false;
    _flushTimer?.cancel();
    _flushTimer = null;
    _pendingColumns.clear();
  }

  Future<void> _onPcm(List<double> samples) async {
    if (!_active || _disposed) return;
    final sender = _sender;
    if (sender == null) return;
    _pendingColumns.addAll(await codec.encodeFrames(samples));
    while (_pendingColumns.length >= framesPerBlock) {
      final block = _pendingColumns.sublist(0, framesPerBlock);
      _pendingColumns.removeRange(0, framesPerBlock);
      sender.sendBlock(block, nowMs: DateTime.now().millisecondsSinceEpoch);
      blocksSent++;
    }
  }

  /// Delivery pump: pushes queued blocks to the transport. In production
  /// the connection fabric calls [deliver] with real transport sends;
  /// here the default pump only runs the queue's flush with the injected
  /// forwarder, if one was set via [onForward].
  Future<bool> Function(DtnBundle bundle)? onForward;

  Future<void> _pump() async {
    final forward = onForward;
    if (forward == null || _disposed) return;
    try {
      await queue.flush(
        (bundle) => forward(bundle),
        nowMs: DateTime.now().millisecondsSinceEpoch,
      );
    } catch (_) {
      // transport died mid-pulse: bundles stay queued (by contract)
    }
  }

  /// Far-end entry point: a delivered bundle payload from the peer.
  Future<void> onRemoteBlock(List<int> payload) async {
    final receiver = _receiver;
    if (receiver == null || _disposed) return;
    for (final block in receiver.offer(payload)) {
      speaker(await codec.decodeFrames(block));
      blocksPlayed++;
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _stop();
    await _stateSub.cancel();
    await _micSub.cancel();
  }
}
