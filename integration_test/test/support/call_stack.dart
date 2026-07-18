/// Builds one endpoint of a loopback call — a real [SignalingClient] wired
/// to a [CallController] over a real WSS socket — shared by the
/// loopback/soak/redaction suites so the wiring exists in exactly one
/// place.
library;

import 'dart:async';

import 'package:call_core/call_core.dart';
import 'package:call_signaling_adapter/call_signaling_adapter.dart';
import 'package:signaling/signaling.dart';
import 'package:signaling_server/signaling_server.dart';

import 'handshaking_fake_media.dart';
import 'ws_connector.dart';

/// This suite is the first place the whole stack meets real sockets (real
/// time, not `fake_async`), so every bound here is short: a stuck
/// handshake must fail the test quickly instead of hanging it.
const testOperationTimeout = Duration(seconds: 6);
const testConnectionTimeout = Duration(seconds: 6);

final testSignalingConfig = SignalingClientConfig(
  heartbeatInterval: Duration(seconds: 2),
  livenessTimeout: Duration(seconds: 5),
  initialReconnectDelay: Duration(milliseconds: 100),
  maxReconnectDelay: Duration(seconds: 1),
  maxReconnectAttempts: 5,
);

/// One side of a call: the real signaling client/gateway plus the
/// `call_core` controller driving it, bundled so tests build, exercise,
/// and tear down both peers symmetrically.
class CallStack {
  CallStack._({
    required this.role,
    required this.client,
    required this.gateway,
    required this.media,
    required this.controller,
  });

  final CallRole role;
  final SignalingClient client;
  final SignalingClientGateway gateway;
  final HandshakingFakeMedia media;
  final CallController controller;

  /// Builds a stack for [role] on [callId], connecting to the relay at
  /// `wss://localhost:$port/`. Does not call [CallController.start] —
  /// callers drive that explicitly so both peers can be started together.
  factory CallStack.build({
    required int port,
    required String callId,
    required CallRole role,
  }) {
    final client = SignalingClient(
      endpoint: Uri.parse('wss://localhost:$port/'),
      localKeyId: '${role.name}-key',
      connector: devWsConnector(),
      config: testSignalingConfig,
    );
    final gateway = SignalingClientGateway(client);
    final media = HandshakingFakeMedia(role: role);
    final controller = CallController(
      callId: callId,
      role: role,
      transport: AdapterCallTransport(gateway),
      signaling: AdapterCallSignaling(gateway),
      media: media,
      reconnectPolicy: ExponentialBackoffReconnectPolicy(
        maxAttempts: 3,
        baseDelay: const Duration(milliseconds: 100),
        maxDelay: const Duration(milliseconds: 500),
        maxElapsed: const Duration(seconds: 5),
      ),
      operationTimeout: testOperationTimeout,
      connectionTimeout: testConnectionTimeout,
    );
    return CallStack._(
      role: role,
      client: client,
      gateway: gateway,
      media: media,
      controller: controller,
    );
  }

  /// Resolves with the first [CallState] where `phase == connected`,
  /// returning immediately if the controller already got there.
  Future<CallState> waitForConnected() {
    if (controller.state.phase == CallPhase.connected) {
      return Future.value(controller.state);
    }
    return controller.states.firstWhere(
      (state) => state.phase == CallPhase.connected,
    );
  }

  /// Disposes the controller (which stops signaling/transport/media) then
  /// the underlying real signaling client, releasing its socket. Both are
  /// required to avoid leaking a live WSS connection per cycle.
  Future<void> dispose() async {
    await controller.dispose();
    await client.dispose();
  }
}

/// Polls [server.activeRooms] until it equals [expected] or [timeout]
/// elapses. A client-side socket `close()` completing does not guarantee
/// the server has already processed the disconnect and torn its room down
/// — that happens on the server's own event loop turn — so a leak check
/// right after `dispose()` needs a short bounded poll instead of an
/// immediate hard assertion.
Future<void> waitForActiveRooms(
  SignalingRelayServer server,
  int expected, {
  Duration timeout = const Duration(seconds: 2),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (server.activeRooms != expected && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
