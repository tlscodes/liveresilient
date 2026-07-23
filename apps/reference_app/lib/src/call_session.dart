/// Composition root for one call session: real `signaling` client over
/// WSS, `call_signaling_adapter` bridges, [WebRtcCallMediaSession] over the
/// real `flutter_webrtc` port, all driven by `call_core`'s
/// [CallController].
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:call_core/call_core.dart';
import 'package:call_media_adapter/call_media_adapter.dart';
import 'package:call_signaling_adapter/call_signaling_adapter.dart';
import 'package:media_webrtc_flutter/media_webrtc_flutter.dart';
import 'package:messaging/messaging.dart';
import 'package:messaging_webrtc_adapter/messaging_webrtc_adapter.dart';
import 'package:signaling/signaling.dart';
import 'media_adaptation_driver.dart';
import 'path_health_monitor.dart';
import 'survival_mode_driver.dart';
import 'ws_connector.dart';

/// One live call session plus the teardown of everything it owns.
class CallSessionHandle {
  CallSessionHandle({
    required this.controller,
    required this.dispose,
    this.openChatPort,
  });

  final CallController controller;

  /// Opens the messaging layer's transport over THIS call's negotiated data
  /// channel (frames ride the call's existing DTLS transport). Both peers
  /// open it with the same default config; null on session builds that have
  /// no media data channel (e.g. pure test fakes).
  final Future<DataChannelPort> Function()? openChatPort;

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
  ClipRecorder? recordVoiceClip,
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
  FlutterWebRtcPeerConnectionPort? livePort;
  final media = WebRtcCallMediaSession(
    () async {
      final port = await FlutterWebRtcPeerConnectionPort.create(audio: true);
      livePort = port;
      return port;
    },
    // The pure port contract has no rollback; the Flutter port does — the
    // adapter package stays pure Dart and gets it through this seam.
    nativeRollback: (port) async {
      if (port is FlutterWebRtcPeerConnectionPort) {
        await port.rollbackLocalDescription();
      }
    },
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
  // Path continuity: score the live media path from its RTC stats counters
  // (EWMA + circuit breaker via adaptive_transport); when the path set goes
  // unhealthy, run the controller's normal reconnect/ICE-restart recovery.
  // The monitor probes only while the call is in its connected phase — the
  // controller already owns recovery for setup/negotiation failures.
  final pathMonitor = buildWebRtcPathHealthMonitor(
    readCounters: () async => livePort?.readStatsCounters(),
    onUnhealthy: () => controller.requestRecovery(),
  );
  // Adaptive quality: under rising loss/RTT the live session steps down
  // bitrate → frame rate → resolution → audio-only, and recovers when
  // conditions improve — applied via standard sender-parameter updates.
  final adaptationDriver = MediaAdaptationDriver(port: () => livePort);
  // Survival mode: the ladder floor / a flapping path flips the call into
  // its first-class degraded phase instead of ever failing; voice-note
  // clips ride the chat outbox. The messenger is created lazily over this
  // call's own data channel and reused for every clip.
  ReliableMessenger? survivalMessenger;
  final survivalDriver = SurvivalModeDriver(
    call: DegradableCallHandle.of(controller),
    adaptationDecisions: adaptationDriver.decisions,
    recordClip: recordVoiceClip,
    messenger: recordVoiceClip == null
        ? null
        : () async => survivalMessenger ??= ReliableMessenger(
            MediaChannelDataPort(await media.openDataChannel()),
            peerId: '${role.name}-survival',
          ),
  );
  final phaseSubscription = controller.states.listen((state) {
    // The two live-quality loops run in BOTH live phases — a degraded call
    // still needs path scoring (to escalate) and adaptation (to climb).
    final live =
        state.phase == CallPhase.connected || state.phase == CallPhase.degraded;
    if (live) {
      pathMonitor.start();
      adaptationDriver.start();
    } else {
      pathMonitor.stop();
      adaptationDriver.stop();
    }
  });
  return CallSessionHandle(
    controller: controller,
    openChatPort: () async =>
        MediaChannelDataPort(await media.openDataChannel()),
    dispose: () async {
      await phaseSubscription.cancel();
      await survivalDriver.dispose();
      await survivalMessenger?.close();
      await pathMonitor.dispose();
      await adaptationDriver.dispose();
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
