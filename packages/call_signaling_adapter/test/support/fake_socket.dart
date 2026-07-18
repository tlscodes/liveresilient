/// Minimal [SignalingSocket] / [SignalingSocketConnector] test doubles for
/// exercising [SignalingClientGateway] against a real [SignalingClient].
///
/// Copied (trimmed to what this package's delegation test needs) from
/// `packages/signaling/test/support/fakes.dart`'s `FakeSocket` /
/// `CountingConnector` — cross-package `test/` files aren't importable via
/// `package:` URIs, so the doubles live here too.
library;

import 'dart:async';

import 'package:signaling/signaling.dart';

/// In-memory [SignalingSocket] double: records every sent frame, lets a
/// test push a raw frame back as if it arrived from the server.
class FakeSocket implements SignalingSocket {
  final _framesController = StreamController<List<int>>.broadcast();
  final List<SignalEnvelope> sentFrames = [];

  bool closed = false;

  @override
  Stream<List<int>> get frames => _framesController.stream;

  @override
  Future<void> sendFrame(List<int> frame) async {
    sentFrames.add(SignalEnvelope.fromBytes(frame));
  }

  @override
  Future<void> close() async {
    closed = true;
  }

  /// Simulates a well-formed envelope arriving from the server.
  void pushInboundEnvelope(SignalEnvelope envelope) {
    if (_framesController.isClosed) return;
    _framesController.add(envelope.toBytes());
  }
}

/// Records every connector invocation and hands out [socket] every time.
class CountingConnector {
  CountingConnector(this.socket);

  final FakeSocket socket;
  final List<Uri> calls = [];

  int get callCount => calls.length;

  Future<SignalingSocket> call(Uri uri) async {
    calls.add(uri);
    return socket;
  }
}
