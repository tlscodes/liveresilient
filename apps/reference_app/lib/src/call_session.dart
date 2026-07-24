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
import 'package:connection_orchestrator/connection_orchestrator.dart';
import 'package:device_link/device_link.dart' show DtnBundleQueue;
import 'package:device_link/durable_store.dart' show DurableBundleStore;
import 'package:media_webrtc_flutter/media_webrtc_flutter.dart';
import 'package:meta/meta.dart';
import 'package:messaging/messaging.dart';
import 'package:messaging_webrtc_adapter/messaging_webrtc_adapter.dart';
import 'package:signaling/signaling.dart';
import 'call_memory.dart';
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
    this.survivalFallbackQueue,
    this.connectionFabric,
  });

  final CallController controller;

  /// The session's unified connectivity fabric: every lane (live media
  /// path today; local-peer and carrier lanes as they come online) plus
  /// the delay-tolerant fallback queue, published as one snapshot stream
  /// for the UI. Null on session builds that skip production wiring.
  final ConnectionFabric? connectionFabric;

  /// The durable (or overridden) queue backing survival-mode's fallback
  /// store, if one was built — exposed for tests to prove restart survival
  /// without reaching into private wiring.
  @visibleForTesting
  final DtnBundleQueue? survivalFallbackQueue;

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
  AudioFrameTap? audioFrameTap,

  /// Directory the survival-mode fallback bundle log lives in. Injectable
  /// so tests control it (and the app can later supply its documents dir)
  /// without this file taking a `path_provider` dependency. Defaults to a
  /// per-callId folder under the system temp dir.
  Directory Function()? storageDirFactory,

  /// Escape hatch: pass `false` to disable the durable fallback store
  /// (falls back to `DtnBundleQueue`'s in-memory default) or pass a
  /// pre-built queue to override it entirely. Defaults to a
  /// `DurableBundleStore`-backed queue keyed on [callId].
  DtnBundleQueue? fallbackBundleQueue,
  bool useDurableFallbackStore = true,
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
  // Durable fallback: clips offered while the call has no live data channel
  // survive a process restart too, backed by a per-call log file on disk.
  final resolvedFallbackQueue =
      fallbackBundleQueue ??
      (useDurableFallbackStore
          ? DtnBundleQueue(
              store: DurableBundleStore.open(
                File(
                  '${(storageDirFactory ?? _defaultSurvivalStorageDir)().path}/'
                  'survival_$callId.jsonl',
                ),
              ),
            )
          : null);
  // Connectivity fabric: the one owner of every lane this session has.
  // Today it carries the live media path and shares the survival fallback
  // queue, so `snapshot.pendingBundles` and `FabricMode` give the UI a
  // single connectivity truth; new lanes (local peer, carrier) register
  // here without touching the call pipeline.
  final fabric = ConnectionFabric(
    fallbackQueue: resolvedFallbackQueue ?? DtnBundleQueue(),
    nowMs: () => DateTime.now().millisecondsSinceEpoch,
  );
  fabric.registerLane(
    WebRtcPathChannel(readCounters: () async => livePort?.readStatsCounters()),
    const LaneProfile(id: 'webrtc-media', kind: LaneKind.internet),
  );
  fabric.onUnhealthy(() => controller.requestRecovery());
  final survivalDriver = SurvivalModeDriver(
    call: DegradableCallHandle.of(controller),
    adaptationDecisions: adaptationDriver.decisions,
    // Foresight feed: the trend watch on the live media lane. Predicting
    // the path will fail shortly flips the call into voice-note mode
    // BEFORE the drop, so the first clips ride a still-half-working link.
    pathFailingSoon: fabric.snapshots.map(
      (snapshot) =>
          snapshot.bestLaneId != null &&
          fabric.trend.verdict(snapshot.bestLaneId!) ==
              TrendVerdict.failingSoon,
    ),
    recordClip: recordVoiceClip,
    fallbackStore: resolvedFallbackQueue,
    messenger: recordVoiceClip == null
        ? null
        : () async => survivalMessenger ??= ReliableMessenger(
            MediaChannelDataPort(await media.openDataChannel()),
            peerId: '${role.name}-survival',
          ),
  );
  // NOTE: the survival driver and call memory share survivalMessenger via
  // the ??= factory, so at most one messenger rides the data channel.
  // Call memory: the outgoing-audio tail buffered before a drop is
  // frozen at the reconnect edge and replayed to the peer once the call
  // is live again — the cut-off sentence still arrives. Active only when
  // the platform provides a frame tap.
  Future<ReliableMessenger> survivalMessengerFactory() async =>
      survivalMessenger ??= ReliableMessenger(
        MediaChannelDataPort(await media.openDataChannel()),
        peerId: '${role.name}-survival',
      );
  final callMemory = audioFrameTap == null
      ? null
      : CallMemory(
          states: controller.states,
          messenger: survivalMessengerFactory,
          tap: audioFrameTap,
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
    survivalFallbackQueue: resolvedFallbackQueue,
    connectionFabric: fabric,
    openChatPort: () async =>
        MediaChannelDataPort(await media.openDataChannel()),
    dispose: () async {
      await phaseSubscription.cancel();
      await callMemory?.dispose();
      await survivalDriver.dispose();
      await survivalMessenger?.close();
      await pathMonitor.dispose();
      await fabric.dispose();
      await adaptationDriver.dispose();
      await controller.dispose();
      await client.dispose();
    },
  );
}

/// Default location for the survival-mode fallback bundle log: a stable
/// subfolder under the system temp dir (created if absent) so restarts on
/// the same device find the same file without a `path_provider` dependency.
Directory _defaultSurvivalStorageDir() {
  final dir = Directory('${Directory.systemTemp.path}/voice_call_kit_survival');
  if (!dir.existsSync()) {
    dir.createSync(recursive: true);
  }
  return dir;
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
