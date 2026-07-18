/// A tiny in-process [DataChannelPort] pair — the same pattern
/// `packages/messaging/test` uses to loopback a [ReliableMessenger] without
/// a real transport, promoted here so the app's Chat tab can exercise the
/// genuine reliable-messaging stack with zero network/server dependency.
library;

import 'dart:async';

import 'package:messaging/messaging.dart';

/// One end of an in-process loopback pair. Frames sent on one end arrive on
/// [peer]'s [inbound] stream on the next microtask.
class LoopbackPort implements DataChannelPort {
  final _inbound = StreamController<List<int>>.broadcast();

  /// The other end of the pair; set by [pairLoopbackPorts].
  LoopbackPort? peer;

  @override
  Stream<List<int>> get inbound => _inbound.stream;

  @override
  Future<void> send(List<int> frame) async {
    peer?._inbound.add(frame);
  }

  @override
  Future<void> close() async {
    if (!_inbound.isClosed) await _inbound.close();
  }
}

/// Creates two [LoopbackPort]s wired to each other.
(LoopbackPort, LoopbackPort) pairLoopbackPorts() {
  final a = LoopbackPort();
  final b = LoopbackPort();
  a.peer = b;
  b.peer = a;
  return (a, b);
}
