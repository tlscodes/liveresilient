/// Shared wiring for the on-device loopback E2E suite: an in-process TLS
/// signaling relay plus two full call stacks (real `SignalingClient` over
/// wss://, real `FlutterWebRtcPeerConnectionPort` over the platform WebRTC
/// engine) inside ONE app process.
///
/// Honest scope (G3 gate shape): loopback signaling + media on one machine,
/// two peers in one process. This does NOT claim the two-device gate (G4).
///
/// Media capture: `getUserMedia(audio)` runs against the real platform.
/// [resolveMediaMode] probes capture once per process with a generous
/// timeout (the macOS TCC prompt may appear once, system-wide); if capture
/// genuinely fails, stacks degrade to no-local-audio ports and every test
/// reports EXACTLY which mode ran — the packet-flow criteria are only
/// claimed when real audio actually flowed (stats counters increasing).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:call_core/call_core.dart';
import 'package:call_signaling_adapter/call_signaling_adapter.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:media_webrtc_flutter/media_webrtc_flutter.dart';
import 'package:reference_app/src/call_session.dart';
import 'package:reference_app/src/webrtc_media_session.dart';
import 'package:signaling/signaling.dart';
import 'package:signaling_server/signaling_server.dart';

import 'e2e_dev_tls.dart';

/// Short bounds: everything here runs on real sockets and the real WebRTC
/// engine, so a stuck step must fail the test with diagnostics, not hang.
const e2eOperationTimeout = Duration(seconds: 15);
const e2eConnectionTimeout = Duration(seconds: 20);

const e2eSignalingConfig = SignalingClientConfig(
  heartbeatInterval: Duration(seconds: 2),
  livenessTimeout: Duration(seconds: 8),
  initialReconnectDelay: Duration(milliseconds: 100),
  maxReconnectDelay: Duration(seconds: 1),
  maxReconnectAttempts: 5,
);

/// TEST-ONLY abuse config, mirroring `bin/load_soak.dart`'s rationale: all
/// loopback clients share the single source key `127.0.0.1` and the soak
/// intentionally creates ~100 rooms fast, which the production defaults
/// (30 msg/s, 20 new callIds/min, 16 rooms/source) would correctly reject.
AbuseControlConfig e2eAbuseControls() => AbuseControlConfig(
  messagesPerSecond: 1000000,
  messageBurst: 1 << 20,
  maxNewCallIdsPerWindow: 1024,
  maxConcurrentRoomsGlobal: 1024,
  maxConcurrentRoomsPerSource: 1024,
  idleRoomTtl: const Duration(minutes: 30),
);

/// The in-process relay over the embedded TEST-ONLY localhost certificate
/// (`e2e_dev_tls.dart` — the sandboxed app cannot spawn `openssl`).
class LoopbackRelay {
  LoopbackRelay._(this.server);

  final SignalingRelayServer server;

  int get port => server.port;

  static Future<LoopbackRelay> start() async {
    final security = SecurityContext()
      ..useCertificateChainBytes(utf8.encode(e2eDevCertificatePem))
      ..usePrivateKeyBytes(utf8.encode(e2eDevPrivateKeyPem));
    final server = await SignalingRelayServer.bind(
      security: security,
      port: 0,
      abuseControls: e2eAbuseControls(),
    );
    return LoopbackRelay._(server);
  }

  Future<void> close() async {
    await server.close();
  }
}

/// Which local media source the run actually used — always reported, never
/// assumed.
enum MediaMode {
  /// `getUserMedia({audio: true})` succeeded: real captured audio tracks.
  realAudio,

  /// Capture failed (documented fallback): peer connections negotiate
  /// recvonly audio m-lines with NO local tracks. ICE/DTLS still connect for
  /// real, but no RTP flows, so packet-flow criteria are DEFERRED.
  noLocalAudio,
}

MediaMode? _resolvedMode;
String? _mediaModeReason;

/// One-shot capture probe (memoized per process). Generous first timeout so
/// a one-time macOS TCC microphone prompt can be answered; on failure the
/// suite continues in [MediaMode.noLocalAudio] and says so.
Future<MediaMode> resolveMediaMode({
  Duration probeTimeout = const Duration(seconds: 30),
}) async {
  final resolved = _resolvedMode;
  if (resolved != null) return resolved;
  try {
    final stream = await rtc.navigator.mediaDevices
        .getUserMedia(<String, dynamic>{'audio': true})
        .timeout(probeTimeout);
    for (final track in stream.getTracks()) {
      await track.stop();
    }
    await stream.dispose();
    _resolvedMode = MediaMode.realAudio;
    _mediaModeReason = 'getUserMedia(audio) succeeded';
  } on Object catch (error) {
    _resolvedMode = MediaMode.noLocalAudio;
    _mediaModeReason = 'getUserMedia(audio) failed: $error';
  }
  // ignore: avoid_print
  print('e2e media mode: ${_resolvedMode!.name} ($_mediaModeReason)');
  return _resolvedMode!;
}

String get mediaModeReason => _mediaModeReason ?? 'probe not run';

/// One side of a loopback call with the REAL media port. Mirrors the
/// phase-3 `CallStack` but swaps `HandshakingFakeMedia` for
/// [WebRtcCallMediaSession] over [FlutterWebRtcPeerConnectionPort], and
/// keeps direct references to the port (stats evidence) and the signaling
/// adapter (to inject `SendRestartRequestCommand` over the real wire).
class E2eCallStack {
  E2eCallStack._({
    required this.role,
    required this.client,
    required this.signalingAdapter,
    required this.media,
    required this.controller,
  });

  final CallRole role;
  final SignalingClient client;
  final AdapterCallSignaling signalingAdapter;
  final WebRtcCallMediaSession media;
  final CallController controller;

  /// Set when the controller starts the media session (port factory runs).
  FlutterWebRtcPeerConnectionPort? port;

  factory E2eCallStack.build({
    required int relayPort,
    required String callId,
    required CallRole role,
    required MediaMode mode,
  }) {
    final client = SignalingClient(
      endpoint: Uri.parse('wss://localhost:$relayPort/'),
      localKeyId: '${role.name}-key',
      connector: devLoopbackWsConnector(),
      config: e2eSignalingConfig,
    );
    final gateway = SignalingClientGateway(client);
    final signalingAdapter = AdapterCallSignaling(gateway);
    late final E2eCallStack stack;
    final media = WebRtcCallMediaSession(() async {
      final port = await FlutterWebRtcPeerConnectionPort.create(
        audio: mode == MediaMode.realAudio,
      ).timeout(const Duration(seconds: 10));
      stack.port = port;
      return port;
    });
    final controller = CallController(
      callId: callId,
      role: role,
      transport: AdapterCallTransport(gateway),
      signaling: signalingAdapter,
      media: media,
      reconnectPolicy: ExponentialBackoffReconnectPolicy(
        maxAttempts: 3,
        baseDelay: const Duration(milliseconds: 100),
        maxDelay: const Duration(milliseconds: 500),
        maxElapsed: const Duration(seconds: 5),
      ),
      operationTimeout: e2eOperationTimeout,
      connectionTimeout: e2eConnectionTimeout,
    );
    stack = E2eCallStack._(
      role: role,
      client: client,
      signalingAdapter: signalingAdapter,
      media: media,
      controller: controller,
    );

    // Room-join beacon: `SignalingRelayServer` pairs sockets purely by each
    // socket's FIRST frame's `callId` (relay_server.dart `_joinRoom`), and
    // neither `call_core` nor `signaling` has an explicit join primitive.
    // The initiator's first frame is naturally its SDP offer, but the
    // receiver has nothing to send until it decodes an inbound offer --
    // which it can only receive after already being in that room. (The
    // client's own periodic heartbeat doesn't help: it hardcodes
    // `callId: 'session'`, a different room.) Enqueue one no-op
    // `callControl` envelope with the REAL callId before `controller.start`
    // runs, so this becomes each socket's first-ever transmitted frame the
    // moment it connects. The unrecognized action is a documented
    // forward-compatible no-op on the decoding side
    // (`envelope_codec.dart: _decodeCallControl`), and the frame IS acked
    // (`callControl` is in `SignalingClient._onFrame`'s acked branch), so
    // this also doubles as an early liveness check -- but nothing here
    // blocks on that ack; it is fire-and-forget by design.
    unawaited(
      client
          .send(
            callId: callId,
            type: SignalType.callControl,
            payload: const {'action': 'e2eJoin'},
          )
          .catchError((Object _) => OutboxOutcome.expired),
    );
    return stack;
  }

  /// First state with `phase == connected`, bounded.
  Future<CallState> waitForConnected({
    Duration timeout = const Duration(seconds: 20),
  }) {
    if (controller.state.phase == CallPhase.connected) {
      return Future.value(controller.state);
    }
    return controller.states
        .firstWhere((state) => state.phase == CallPhase.connected)
        .timeout(
          timeout,
          onTimeout: () => throw TimeoutException(
            '${role.name} never reached connected; '
            'last phase=${controller.state.phase.name} '
            'error=${controller.state.error}',
          ),
        );
  }

  /// Controller first (stops media -> closes the port), then the socket.
  Future<void> dispose() async {
    await controller.dispose();
    await client.dispose();
  }
}

/// Polls the relay until [expected] rooms remain (server-side teardown runs
/// on its own event-loop turn after the client socket closes).
Future<void> waitForActiveRooms(
  SignalingRelayServer server,
  int expected, {
  Duration timeout = const Duration(seconds: 3),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (server.activeRooms != expected && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

/// Samples `readStatsCounters().packetsReceived` on [port] until it has
/// seen [increases] strictly-increasing steps (so `increases + 1` samples,
/// each strictly greater than the last). Returns every accepted sample.
/// Throws with full diagnostics if the deadline passes first.
Future<List<int>> samplePacketsReceivedStrictlyIncreasing(
  FlutterWebRtcPeerConnectionPort port, {
  required String label,
  int increases = 3,
  Duration interval = const Duration(milliseconds: 400),
  Duration timeout = const Duration(seconds: 25),
}) async {
  final deadline = DateTime.now().add(timeout);
  final accepted = <int>[];
  final rawReadings = <int>[];
  while (DateTime.now().isBefore(deadline)) {
    final counters = await port.readStatsCounters().timeout(
      const Duration(seconds: 5),
    );
    final received = counters?.packetsReceived;
    if (received != null) {
      rawReadings.add(received);
      if (accepted.isEmpty || received > accepted.last) {
        accepted.add(received);
        if (accepted.length >= increases + 1) {
          return accepted;
        }
      }
    }
    await Future<void>.delayed(interval);
  }
  throw TimeoutException(
    '$label: packetsReceived did not strictly increase '
    '${increases + 1} times within $timeout; '
    'accepted=$accepted rawReadings=$rawReadings',
  );
}
