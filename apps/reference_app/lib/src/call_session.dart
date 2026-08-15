/// Composition root for one call session: real `signaling` client over
/// WSS, `call_signaling_adapter` bridges, [WebRtcCallMediaSession] over the
/// real `flutter_webrtc` port, all driven by `call_core`'s
/// [CallController].
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:call_core/call_core.dart';
import 'package:call_media_adapter/call_media_adapter.dart';
import 'package:call_signaling_adapter/call_signaling_adapter.dart';
import 'package:connection_orchestrator/connection_orchestrator.dart';
import 'package:device_link/device_link.dart' show DtnBundleQueue;
import 'package:device_link/durable_store.dart' show DurableBundleStore;
import 'package:media_webrtc/media_webrtc.dart'
    show
        CallAdmissionRefused,
        OpusSdpPolicy,
        OpusWireBudget,
        OpusWireFitted,
        OpusWireUnconstrained,
        OpusWireNoCandidateFits;
import 'package:media_webrtc_flutter/media_webrtc_flutter.dart';
import 'package:signed_config/signed_config.dart';
import 'package:meta/meta.dart';
import 'package:messaging/messaging.dart';
import 'package:messaging_webrtc_adapter/messaging_webrtc_adapter.dart';
import 'package:signaling/signaling.dart';
import 'call_memory.dart';
import 'intelligence/intelligence_hub.dart';
import 'media_adaptation_driver.dart';
import 'path_health_monitor.dart';
import 'degraded_mode_driver.dart';
import 'ws_connector.dart';

/// One live call session plus the teardown of everything it owns.
class CallSessionHandle {
  CallSessionHandle({
    required this.controller,
    required this.dispose,
    this.openChatPort,
    this.dtnFallbackQueue,
    this.connectionFabric,
    this.connectionBudget,
  });

  final CallController controller;

  /// The deadlines this session was built with, and the model behind them.
  ///
  /// Exposed so a test can assert that the call connected within
  /// [AdaptiveConnectionBudget.expectedConnectBy] — roughly one modelled
  /// attempt — rather than merely inside the retry budget. Without that
  /// assertion a widened budget would hide a genuine connect defect instead of
  /// reporting it. Null on session builds that skip production wiring.
  final AdaptiveConnectionBudget? connectionBudget;

  /// The session's unified connectivity fabric: every lane (live media
  /// path today; local-peer and carrier lanes as they come online) plus
  /// the delay-tolerant fallback queue, published as one snapshot stream
  /// for the UI. Null on session builds that skip production wiring.
  final ConnectionFabric? connectionFabric;

  /// The durable (or overridden) queue backing degraded-mode's fallback
  /// store, if one was built — exposed for tests to prove the queue survives a restart
  /// without reaching into private wiring.
  @visibleForTesting
  final DtnBundleQueue? dtnFallbackQueue;

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

/// Mints a call id with enough entropy to double as a relay session id.
///
/// The call id is what pairs two peers on the border relay, so it is a
/// shared secret: anyone holding it can attach as the missing side. A
/// sequential or human-chosen id is therefore a hijacking risk, not a
/// cosmetic choice. [bytes] defaults to 16 — 128 bits, drawn from
/// [Random.secure], which is the platform CSPRNG.
///
/// The alphabet is base64url without padding, which is exactly the
/// character set the relay accepts, so the id needs no sanitising later.
String newSecureCallId({int bytes = 16}) {
  if (bytes < 16) {
    throw ArgumentError.value(bytes, 'bytes', 'needs at least 16 (128 bits)');
  }
  final random = Random.secure();
  final entropy = Uint8List.fromList(
    List<int>.generate(bytes, (_) => random.nextInt(256)),
  );
  return base64UrlEncode(entropy).replaceAll('=', '');
}

/// The deployed border relay, used when nothing in the environment names
/// one. Source lives in `tools/cloudflare_relay_worker`.
const String defaultBorderRelayHost =
    'voice-call-relay.tlscodes-com.workers.dev';

/// The WAN fallback lanes for [callId], pointed at [defaultBorderRelayHost].
///
/// The call id doubles as the relay session id, so both peers of one call
/// meet on the same relay session without another identifier to exchange.
/// That makes the call id a shared secret: anyone who holds it can attach
/// to the relay as the missing side. Call ids must be unguessable.
///
/// Roles follow the call: the initiator is `'a'`, the responder `'b'`, so
/// each side reads what the other wrote.
///
/// No UDP lane — the relay speaks HTTP and WebSocket only. Set
/// `FALLBACK_UDP_ENDPOINT` to add a direct media endpoint of your own.
ResilientLaneEndpoints defaultBorderRelayEndpoints({
  required String callId,
  required CallRole role,
  String relayHost = defaultBorderRelayHost,
}) {
  // The relay accepts [A-Za-z0-9._-]; anything else in a call id is
  // replaced rather than rejected, so an id with a colon or slash in it
  // still yields a usable session instead of failing the whole call.
  final session = callId.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '-');
  return ResilientLaneEndpoints.cloudflareWorker(
    workerHost: relayHost,
    session: session.isEmpty ? 'unnamed' : session,
    role: role == CallRole.initiator ? 'a' : 'b',
  );
}

/// Production wiring (mirrors the integration suite's `CallStack`, with the
/// real WebRTC media session instead of the handshake fake).
CallSessionHandle buildWebRtcCallSession({
  required Uri endpoint,
  required String callId,
  required CallRole role,
  /// Maps a host name to an address, asynchronously, once per connection
  /// attempt (ticket 6). The name is an input the HTTP stack produces at
  /// connect time and a redirect can introduce a new one mid-flight, so this
  /// is never pre-resolved into a fixed set.
  Future<String?> Function(String host)? resolveAddress,
  String Function(Uri uri)? proxyResolver,
  void Function(HttpClient client)? proxyConfigurator,
  SecurityContext? securityContext,
  ClipRecorder? recordVoiceClip,
  AudioFrameTap? audioFrameTap,
  /// Whether a fixed-tick emitter governs this call's output rate. It
  /// decides the codec's silence handling (gate 1e), so it is stated here
  /// rather than inferred: false is today's behaviour everywhere.
  bool fixedTickEmitterRunning = false,

  /// The signed manifest's STUN/TURN servers, mapped for the peer connection.
  ///
  /// Until this existed the port was created with its `iceServers` default of
  /// `const []`, so every call was placed with no STUN and no TURN and only
  /// connected when both peers happened to be directly reachable. Build it with
  /// `buildRtcIceConfig(manifest, profile: ...)`. Null keeps the old behaviour
  /// for callers that have no manifest yet.
  RtcIceConfig? iceConfig,

  /// Opus knobs applied to every local description: in-band FEC on, DTX off.
  /// Null derives the rate/ptime from [initialConditions]' bandwidth via
  /// [OpusWireBudget] when the link capacity is known (measured 2026-08-06:
  /// an unbudgeted default stream saturated a 32 kbit/s link and starved
  /// the signaling until liveness killed the call), and leaves the stack's
  /// defaults on an unknown link — which is what shipped before.
  OpusSdpPolicy? opusPolicy,

  /// Directory the degraded-mode fallback bundle log lives in. Injectable
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

  /// Endpoints for the resilient fallback stack (direct UDP, WebSocket
  /// relay, HTTP long-poll, local mesh). Each configured lane is built and
  /// registered with the session's fabric alongside the live WebRTC path,
  /// so the fabric can fail over when that path dies. Lanes left
  /// unconfigured are simply absent — the call still runs on WebRTC alone.
  ///
  /// Defaults to whatever `FALLBACK_UDP_ENDPOINT`, `FALLBACK_WS_ENDPOINT`
  /// and `FALLBACK_HTTP_ENDPOINT` name in the process environment, so a
  /// deployment configures its border relays without a code change. Pass a
  /// value explicitly to bypass the environment entirely (what the tests
  /// do).
  ResilientLaneEndpoints? fallbackLanes,

  /// What the path is known to cost before a candidate pair exists.
  ///
  /// The first connect has no candidate pair to measure, so live RTC stats
  /// cannot bootstrap the budget — something has to state the starting
  /// assumption. A deployment that knows nothing leaves this at
  /// [NetworkConditions.pristine] and gets the old tight deadlines; the shaped
  /// test rig knows the profile exactly and passes it, so the harness and the
  /// app run one formula instead of two constants that drift apart.
  NetworkConditions initialConditions = NetworkConditions.pristine,

  /// Optional intelligence tap: when present, the session's measured
  /// call-end statistics feed the personal brains (RIG_GUIDE «هوشمندی v3»
  /// wiring matrix). Absent (all current tests) = zero behavior change.
  IntelligenceHub? hub,
  int Function()? nowMs,
}) {
  final now = nowMs ?? () => DateTime.now().millisecondsSinceEpoch;
  final startedUtcMs = now();
  final connectionBudget =
      AdaptiveConnectionBudget.fromConditions(initialConditions);
  // What the AUDIO may cost on this link. Derived from the same conditions
  // as the connect budget so the two survival models cannot drift; 30% of
  // the link is reserved for the control plane (see OpusWireBudget).
  // Duplex: both parties' audio shares every crossing of the same pipe,
  // and DTX makes the silent side nearly free on the wire — without it a
  // "fitting" config still queued the link to death on the 16 kbit/s row
  // (measured 2026-08-08; the no-audio control run delivered clean).
  // Admission is ONE decision. The link's capacity is priced by
  // OpusWireBudget; whether the emitter's fixed tick has room under the
  // interactive delay budget is a bound only call_core can compute, because
  // it depends on the path's one-way delay. Injecting it here folds the two
  // into a single verdict with named causes — the alternative was two
  // components each holding a veto with no defined precedence, so a link
  // with ample bandwidth was admitted here and refused downstream purely
  // because the round trip was long.
  final wireAdmission = OpusWireBudget.forBandwidth(
    initialConditions.bandwidthBps,
    concurrentStreams: 2,
    tickProbe:
        ({
          required int wireRateBps,
          required double perStreamBudgetBps,
          required int frameBitsOnWire,
        }) =>
            connectionBudget.maxSchedulerStepFor(
              initialConditions,
              offeredRateBps: wireRateBps,
              usableShareBps: perStreamBudgetBps.round(),
              frameBits: frameBitsOnWire,
            ) is SchedulerStepAdmissible,
  );
  // The refusal is binding. Placing the call at the cheapest configuration
  // anyway is what the old code did, and it survived only because the codec
  // suppressed output during silence: the real mean sat far below the
  // nominal rate. With a fixed-tick emitter running, the nominal rate IS the
  // sustained rate, so offering more than the pipe carries is an unbounded
  // queue and the death of both directions. A refusal reaches the caller
  // carrying its numbers instead.
  final OpusWireBudget wireBudget = switch (wireAdmission) {
    OpusWireFitted(:final budget) => budget,
    OpusWireUnconstrained(:final budget) => budget,
    OpusWireNoCandidateFits() => throw CallAdmissionRefused(wireAdmission),
  };
  final constrainedLink = initialConditions.bandwidthBps != null &&
      initialConditions.bandwidthBps! > 0;
  // Gate 1e: silence handling is derived from the shaping state, not set by
  // hand. With the fixed-tick emitter off — the default everywhere today —
  // this yields exactly the previous policy: DTX on, constant bitrate off.
  final effectiveOpusPolicy = opusPolicy ??
      (constrainedLink
          ? OpusSdpPolicy.forShapingState(
              fixedTickEmitterRunning: fixedTickEmitterRunning,
              maxAverageBitrateBps: wireBudget.opusRateBps,
              ptimeMs: wireBudget.ptimeMs,
            )
          : null);
  // Keepalive timing from the same conditions model as the connect budget:
  // the class defaults are the pristine floors (an unconstrained deployment
  // is bit-for-bit unchanged); a known-hostile path gets the patience its
  // physics demand. Measured 2026-08-06 (T2 loss60): a fixed liveness window
  // on a 60%-loss link declared live sockets dead every window and the
  // reconnect loop ate the whole connect budget.
  final signalingDefaults = SignalingClientConfig();
  final signalingTiming = connectionBudget.signalingTiming(
    heartbeatFloor: signalingDefaults.heartbeatInterval,
    livenessFloor: signalingDefaults.livenessTimeout,
    connectTimeoutFloor: signalingDefaults.connectTimeout,
    reconnectAttemptsFloor: signalingDefaults.maxReconnectAttempts,
  );
  final client = SignalingClient(
    endpoint: endpoint,
    localKeyId: '${role.name}-key',
    config: SignalingClientConfig(
      heartbeatInterval: signalingTiming.heartbeatInterval,
      livenessTimeout: signalingTiming.livenessTimeout,
      initialReconnectDelay: signalingDefaults.initialReconnectDelay,
      maxReconnectDelay: signalingDefaults.maxReconnectDelay,
      maxReconnectAttempts: signalingTiming.maxReconnectAttempts,
      maxEnvelopeAge: signalingDefaults.maxEnvelopeAge,
      connectTimeout: signalingTiming.connectTimeout,
      outboxMessageLifetime: signalingTiming.messageLifetime,
    ),
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
      final port = await FlutterWebRtcPeerConnectionPort.create(
        audio: true,
        iceServers: iceConfig?.iceServers ?? const [],
        iceTransportPolicy: iceConfig?.iceTransportPolicy ?? 'all',
        opusPolicy: effectiveOpusPolicy,
      );
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
  // Per-operation deadlines, same three classes the e2e harness proved on
  // the T2 matrix (one 15 s constant used to bound all three):
  //   class A — one signaling send-and-ack. Nominal 1 round trip, but the
  //     bound absorbs the worst LEGITIMATE case: a liveness window to even
  //     notice a dead socket, then TCP+TLS+WS re-establishment and the
  //     resent frame's ack (5 round trips).
  //   class B — the media (re)connection wait: one full 8-round-trip
  //     ICE + DTLS + first-media attempt.
  //   class C — local engine calls: zero network, so the bound stays FIXED;
  //     a hung engine is a defect to detect fast, not weather to wait out.
  // Floors are the shipped constants, so an unconstrained deployment is
  // unchanged; a known-hostile path gets what its physics cost.
  // No liveness detection floor: the outbox is at-least-once (a timed-out
  // await abandons nothing) and the liveness timer handles dead sockets
  // independently — wire-measured 2026-08-07, see the e2e harness's
  // class-A dartdoc for the capture evidence.
  final derivedOperationTimeout = connectionBudget.operationBudget(
    roundTrips: 5,
  );
  const legacyOperationTimeout = Duration(seconds: 15);
  const legacyConnectionTimeout = Duration(seconds: 20);
  final derivedConnectionTimeout = connectionBudget.operationBudget(
    roundTrips: AdaptiveConnectionBudget.handshakeRoundTrips,
  );
  final controller = CallController(
    callId: callId,
    role: role,
    transport: AdapterCallTransport(gateway),
    signaling: AdapterCallSignaling(gateway),
    media: media,
    // The deadline is derived from what the path costs, not from a constant.
    // The constant it replaces (15s) was calibrated on a ~0.7s round-trip; one
    // ICE+DTLS+first-media attempt costs roughly eight round trips, so at the
    // 1.8s-RTT profile a single clean attempt already needs 18.4s and was being
    // severed mid-handshake. On a healthy link the budget tightens back to its
    // 30s floor, so this cannot quietly excuse a slow connect.
    reconnectPolicy: connectionBudget.toReconnectPolicy(),
    operationTimeout: derivedOperationTimeout >= legacyOperationTimeout
        ? derivedOperationTimeout
        : legacyOperationTimeout,
    connectionTimeout: derivedConnectionTimeout >= legacyConnectionTimeout
        ? derivedConnectionTimeout
        : legacyConnectionTimeout,
    engineOperationTimeout: legacyOperationTimeout,
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
  final adaptationDriver = MediaAdaptationDriver(
    port: () => livePort,
    audioCeilingBps: constrainedLink ? wireBudget.opusRateBps : null,
  );
  // Survival mode: the ladder floor / a flapping path flips the call into
  // its first-class degraded phase instead of ever failing; voice-note
  // clips ride the chat outbox. The messenger is created lazily over this
  // call's own data channel and reused for every clip.
  ReliableMessenger? storeAndForwardMessenger;
  // Durable fallback: clips offered while the call has no live data channel
  // survive a process restart too, backed by a per-call log file on disk.
  final resolvedFallbackQueue =
      fallbackBundleQueue ??
      (useDurableFallbackStore
          ? DtnBundleQueue(
              store: DurableBundleStore.open(
                File(
                  '${(storageDirFactory ?? _defaultStoreAndForwardDir)().path}/'
                  'survival_$callId.jsonl',
                ),
              ),
            )
          : null);
  // Connectivity fabric: the one owner of every lane this session has.
  // Today it carries the live media path and shares the store-and-forward fallback
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
  // The fallback stack, ranked behind the live media path by its own cost
  // ranks. Registered here rather than at first failure so the fabric has
  // health history on each lane before it has to choose one.
  ResilientFallbackLanes.buildAndRegister(
    fabric,
    fallbackLanes ??
        ResilientLaneEndpoints.fromEnvironment(
          Platform.environment,
          defaults: defaultBorderRelayEndpoints(callId: callId, role: role),
        ),
  );
  fabric.onUnhealthy(() => controller.requestRecovery());
  final degradedModeDriver = DegradedModeDriver(
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
        : () async => storeAndForwardMessenger ??= ReliableMessenger(
            MediaChannelDataPort(await media.openDataChannel()),
            peerId: '${role.name}-survival',
          ),
  );
  // NOTE: the degraded-mode driver and call memory share storeAndForwardMessenger via
  // the ??= factory, so at most one messenger rides the data channel.
  // Call memory: the outgoing-audio tail buffered before a drop is
  // frozen at the reconnect edge and replayed to the peer once the call
  // is live again — the cut-off sentence still arrives. Active only when
  // the platform provides a frame tap.
  Future<ReliableMessenger> storeAndForwardMessengerFactory() async =>
      storeAndForwardMessenger ??= ReliableMessenger(
        MediaChannelDataPort(await media.openDataChannel()),
        peerId: '${role.name}-survival',
      );
  final callMemory = audioFrameTap == null
      ? null
      : CallMemory(
          states: controller.states,
          messenger: storeAndForwardMessengerFactory,
          tap: audioFrameTap,
        );
  // Call-end statistics for the intelligence brains. connectMs stays null
  // until the first connected phase; a never-connected call is recorded
  // nowhere (a required-int sentinel would poison the budget calibrator).
  int? connectMs;
  var recoveries = 0;
  var dropsToFloor = 0;
  String? terminalReason;
  CallPhase? lastPhase;
  final phaseSubscription = controller.states.listen((state) {
    if (connectMs == null && state.phase == CallPhase.connected) {
      connectMs = now() - startedUtcMs;
    }
    if (state is TerminalCallState) {
      terminalReason = state.endReason.name;
    }
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
      // Recovery starves on a constrained pipe if the still-flowing RTP
      // keeps its rate: floor the sender NOW so the ICE-restart handshake
      // owns the link (measured 2026-08-06 — every T2 bandwidth/narrow/
      // extreme death was in this phase, never mid-call).
      if (state.phase == CallPhase.reconnecting) {
        // Edge-triggered on the phase transition: each retry emits a fresh
        // ReconnectingCallState, so counting emissions would over-count.
        if (lastPhase != CallPhase.reconnecting) {
          recoveries += 1;
          // Shipped definition: episodes that forced the survival floor
          // (not per-emission floor calls, not adaptation-ladder floors).
          dropsToFloor += 1;
        }
        unawaited(adaptationDriver.applySurvivalFloor());
      }
    }
    lastPhase = state.phase;
  });
  return CallSessionHandle(
    connectionBudget: connectionBudget,
    controller: controller,
    dtnFallbackQueue: resolvedFallbackQueue,
    connectionFabric: fabric,
    openChatPort: () async =>
        MediaChannelDataPort(await media.openDataChannel()),
    dispose: () async {
      // Record once, before the hub's savers could be disposed by the
      // caller (a markDirty after saver disposal is a silent no-op and
      // the record would exist in memory only). Never-connected calls
      // are skipped: connectMs is the calibrator's training input.
      final measuredConnectMs = connectMs;
      if (hub != null && measuredConnectMs != null) {
        hub.recordCallEnd(
          CallHistoryRecord(
            startedUtcMs: startedUtcMs,
            connectMs: measuredConnectMs,
            recoveries: recoveries,
            dropsToFloor: dropsToFloor,
            networkIdentityHash: NetworkAtlas.identityHash(
              hub.resolver.lastKnownLabel,
            ),
            endReason: terminalReason ?? 'disposed',
          ),
          predictedConnectMs: connectionBudget.expectedConnectBy.inMilliseconds
              .toDouble(),
        );
        connectMs = null; // idempotence: a second dispose records nothing
      }
      await phaseSubscription.cancel();
      await callMemory?.dispose();
      await degradedModeDriver.dispose();
      await storeAndForwardMessenger?.close();
      await pathMonitor.dispose();
      await fabric.dispose();
      await adaptationDriver.dispose();
      await controller.dispose();
      await client.dispose();
    },
  );
}

/// Default location for the degraded-mode fallback bundle log: a stable
/// subfolder under the system temp dir (created if absent) so restarts on
/// the same device find the same file without a `path_provider` dependency.
Directory _defaultStoreAndForwardDir() {
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
