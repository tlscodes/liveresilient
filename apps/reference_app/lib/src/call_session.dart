/// Composition root for one call session: real `signaling` client over
/// WSS, `call_signaling_adapter` bridges, [WebRtcCallMediaSession] over the
/// real `flutter_webrtc` port, all driven by `call_core`'s
/// [CallController].
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:call_core/call_core.dart';
import 'package:call_signaling_adapter/call_signaling_adapter.dart';
import 'package:media_webrtc_flutter/media_webrtc_flutter.dart';
import 'package:signaling/signaling.dart';
import 'ws_connector.dart';

import 'webrtc_media_session.dart';

/// One live call session plus the teardown of everything it owns.
class CallSessionHandle {
  CallSessionHandle({required this.controller, required this.dispose});

  final CallController controller;

  /// Tears down the controller and everything the session owns (e.g. the
  /// real signaling client's socket).
  final Future<void> Function() dispose;
}

/// Builds a session; injectable so widget tests swap in fakes.
typedef CallSessionBuilder =
    CallSessionHandle Function({
      required Uri endpoint,
      required String callId,
      required CallRole role,
    });

/// Production wiring (mirrors the integration suite's `CallStack`, with the
/// real WebRTC media session instead of the handshake fake).
CallSessionHandle buildWebRtcCallSession({
  required Uri endpoint,
  required String callId,
  required CallRole role,
  String? Function(String host)? resolveAddress,
  String Function(Uri uri)? proxyResolver,
  void Function(HttpClient client)? proxyConfigurator,
  SecurityContext? securityContext,
}) {
  final client = SignalingClient(
    endpoint: endpoint,
    localKeyId: '${role.name}-key',
    connector: (uri) async {
      final socket = await connectWebSocketWithCustomRules(
        uri,
        hostResolver: resolveAddress,
        proxyResolver: proxyResolver,
        proxyConfigurator: proxyConfigurator,
        securityContext: securityContext,
      );
      return _IoSignalingSocket(socket);
    },
  );
  final gateway = SignalingClientGateway(client);
  final media = WebRtcCallMediaSession(
    () => FlutterWebRtcPeerConnectionPort.create(audio: true),
  );
  final controller = CallController(
    callId: callId,
    role: role,
    transport: AdapterCallTransport(gateway),
    signaling: AdapterCallSignaling(gateway),
    media: media,
    reconnectPolicy: ExponentialBackoffReconnectPolicy(
      maxAttempts: 5,
      baseDelay: const Duration(milliseconds: 250),
      maxDelay: const Duration(seconds: 2),
      maxElapsed: const Duration(seconds: 15),
    ),
  );
  return CallSessionHandle(
    controller: controller,
    dispose: () async {
      await controller.dispose();
      await client.dispose();
    },
  );
}

/// Real `dart:io` WebSocket connector for [SignalingClient].
///
/// DEV-ONLY certificate posture: the local signaling relay uses a
/// self-signed localhost certificate, so certificate validation is relaxed
/// for loopback hosts ONLY — any non-loopback endpoint keeps full TLS
/// validation. A production connector must pin/validate instead.
SignalingSocketConnector devLoopbackWsConnector() {
  return (Uri uri) async {
    final client = HttpClient()
      ..badCertificateCallback = (X509Certificate cert, String host, int port) {
        return host == 'localhost' || host == '127.0.0.1' || host == '::1';
      };
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
        if (_frames.isClosed) return;
        if (event is List<int>) {
          _frames.add(event);
        } else if (event is String) {
          _frames.add(utf8.encode(event));
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!_frames.isClosed) {
          _frames.addError(error, stackTrace);
        }
      },
      onDone: () {
        if (!_frames.isClosed) {
          _frames.close();
        }
      },
      cancelOnError: false,
    );
  }

  final WebSocket _socket;
  final StreamController<List<int>> _frames =
      StreamController<List<int>>.broadcast();
  late final StreamSubscription<dynamic> _subscription;

  @override
  Stream<List<int>> get frames => _frames.stream;

  @override
  Future<void> sendFrame(List<int> frame) async {
    _socket.add(frame);
  }

  @override
  Future<void> close() async {
    await _subscription.cancel();
    await _socket.close();
    if (!_frames.isClosed) {
      await _frames.close();
    }
  }
}
