/// Real `dart:io` WebSocket transport for [SignalingClient], tolerant of
/// the self-signed dev certificate [ensureDevCertificate] produces.
///
/// This is the first place in the stack a [SignalingSocketConnector] is
/// backed by a real socket instead of an in-memory fake — everything below
/// runs on REAL time (no `fake_async`), so callers must keep their own
/// timeouts short (see `support/call_stack.dart`) rather than relying on a
/// virtual clock to fail fast.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:signaling/signaling.dart';

/// Builds a [SignalingSocketConnector] that accepts the relay's self-signed
/// localhost dev certificate. Test-only: a production connector must never
/// disable certificate validation.
SignalingSocketConnector devWsConnector() {
  return (Uri uri) async {
    final client = HttpClient()
      ..badCertificateCallback =
          (X509Certificate cert, String host, int port) => true;
    final socket = await WebSocket.connect(
      uri.toString(),
      customClient: client,
    );
    return _IoSignalingSocket(socket);
  };
}

class _IoSignalingSocket implements SignalingSocket {
  _IoSignalingSocket(this._socket) {
    _subscription = _socket.listen(
      (dynamic event) {
        if (_framesController.isClosed) return;
        if (event is List<int>) {
          _framesController.add(event);
        } else if (event is String) {
          _framesController.add(utf8.encode(event));
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!_framesController.isClosed) {
          _framesController.addError(error, stackTrace);
        }
      },
      onDone: () {
        if (!_framesController.isClosed) {
          _framesController.close();
        }
      },
      cancelOnError: false,
    );
  }

  final WebSocket _socket;
  final StreamController<List<int>> _framesController =
      StreamController<List<int>>.broadcast();
  late final StreamSubscription<dynamic> _subscription;

  @override
  Stream<List<int>> get frames => _framesController.stream;

  @override
  Future<void> sendFrame(List<int> frame) async {
    _socket.add(frame);
  }

  @override
  Future<void> close() async {
    await _subscription.cancel();
    await _socket.close();
    if (!_framesController.isClosed) {
      await _framesController.close();
    }
  }
}
