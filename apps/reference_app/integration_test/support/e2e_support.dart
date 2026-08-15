/// Shared wiring for the on-device loopback E2E suite: an in-process TLS
/// signaling relay plus two full call stacks (real `SignalingClient` over
/// wss://, real `FlutterWebRtcPeerConnectionPort` over the platform WebRTC
/// engine) inside ONE app process.
// Evidence lines (phases, inbound envelopes) print to the test log by design.
// ignore_for_file: avoid_print
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
import 'package:connection_orchestrator/connection_orchestrator.dart'
    show TrendMonitor, TrendVerdict;
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:signed_config/signed_config.dart'
    show IceProfile, iceProfileFor;
import 'package:media_webrtc/media_webrtc.dart'
    show
        CallAdmissionRefused,
        OpusSdpPolicy,
        OpusWireBudget,
        OpusWireFitted,
        OpusWireUnconstrained,
        OpusWireNoCandidateFits,
        PeerConnectionStatus;
import 'package:media_webrtc_flutter/media_webrtc_flutter.dart';
import 'package:call_media_adapter/call_media_adapter.dart';
import 'package:reference_app/src/media_adaptation_driver.dart';
import 'package:signaling/signaling.dart';
import 'package:signaling_server/signaling_server.dart';

import 'e2e_dev_tls.dart';

// ---------------------------------------------------------------------------
// RIG CONFIGURATION (compile-time, via --dart-define)
//
// By default this suite is the honest in-process loopback it always was
// (G3 shape: both stacks and the relay in ONE app process — nothing crosses
// any real interface). The H2 shaped-network harness (tools/t2/h2_run.sh)
// overrides these so the traffic REALLY crosses the shaped bridge:
//
//   E2E_RELAY_URI   e.g. wss://192.168.3.1:8443/ — a relay hosted on the Mac
//                   (server/signaling_server), so signalling crosses bridge100
//                   as real TCP instead of terminating inside this process.
//   E2E_TURN_URI    e.g. turn:192.168.3.1:3478 — the dev coturn on the Mac.
//   E2E_FORCE_RELAY true → iceTransportPolicy 'relay': every RTP/RTCP packet
//                   is forced to hairpin phone -> Mac TURN -> phone over UDP,
//                   crossing the shaped interface twice. Without this, both
//                   peers live in one process and ICE picks host candidates
//                   that never leave the phone — which is exactly the
//                   loopback-wearing-a-shaped-label defect the harness
//                   guards against.
// ---------------------------------------------------------------------------
const String e2eRelayUriOverride = String.fromEnvironment('E2E_RELAY_URI');
const String e2eTurnUri = String.fromEnvironment('E2E_TURN_URI');
const String e2eTurnUser = String.fromEnvironment(
  'E2E_TURN_USER',
  defaultValue: 'dev',
);
const String e2eTurnPass = String.fromEnvironment(
  'E2E_TURN_PASS',
  defaultValue: 'devpass',
);
const bool e2eForceRelay = bool.fromEnvironment('E2E_FORCE_RELAY');

/// The ICE transport policy for a rig row, decided by the SAME function
/// production uses (gate 3c).
///
/// The flag used to pick the policy string directly. That made the rig prove
/// something about a code path production never takes: the profile rule in
/// `iceProfileFor` was bypassed entirely, so a defect in it could not be
/// caught here. The flag now enters where a deployment's own flag would —
/// through the manifest's feature flags — and the policy string is whatever
/// the production mapper derives from the resulting profile.
String e2eIceTransportPolicy() {
  final profile = iceProfileFor(
    iceFailureCount: 0,
    featureFlags: <String, bool>{'strict_relay': e2eForceRelay},
  );
  return profile == IceProfile.strictRelay ? 'relay' : 'all';
}

/// True when the suite runs against an off-device rig instead of pure
/// in-process loopback. Tests that assert on the in-process relay's internal
/// state (activeRooms) must skip those assertions in this mode.
bool get e2eUsesRemoteRelay => e2eRelayUriOverride.isNotEmpty;

List<Map<String, Object>> e2eIceServers() {
  if (e2eTurnUri.isEmpty) return const [];
  return [
    {
      'urls': e2eTurnUri,
      'username': e2eTurnUser,
      'credential': e2eTurnPass,
    },
    // Reliable-transport fallback (2026-08-08, loss60 design): the same
    // media relay over TCP. Under heavy random loss the UDP handshake's
    // internal retransmit timers are not tunable from Dart, so candidate
    // and DTLS delivery is a lottery; the TCP entry rides retransmission
    // below ICE and turns that delivery into a bounded wait. The UDP
    // entry stays first — when it wins, it wins faster. The rig shapes
    // this TCP port too (h2_run.sh T2_SHAPE_TCP_PORT): an unshaped path
    // would be an unshaped metric.
    {
      'urls': '$e2eTurnUri?transport=tcp',
      'username': e2eTurnUser,
      'credential': e2eTurnPass,
    },
  ];
}

/// Like `devLoopbackWsConnector`, but also relaxes certificate validation for
/// the configured E2E relay host (the Mac's bridge address). TEST-ONLY: the
/// relay presents the well-known dev certificate; there is nothing to protect.
SignalingSocketConnector e2eWsConnector(Uri endpoint) {
  // ONE HttpClient PER DIAL, deliberately. A shared client was tried
  // (2026-08-07) for its TLS session cache and measured to make things
  // strictly worse: its connection pool queues each new dial behind the
  // still-pending previous one, so a single stalled handshake became
  // head-of-line for every retry — 45 clockwork dials, zero completions
  // on the wire. Independent clients make every dial an independent
  // sample, which is the entire point of dial cadence under loss; the
  // session-resumption saving is void anyway until a first handshake
  // completes.
  HttpClient newClient() => HttpClient()
    ..badCertificateCallback = (X509Certificate cert, String host, int port) {
      return host == 'localhost' ||
          host == '127.0.0.1' ||
          host == '::1' ||
          host == endpoint.host;
    };
  // HAPPY-EYEBALLS DIAL (RFC 8305 spirit, applied to one endpoint): three
  // staggered parallel connects, first completed handshake wins. Wire
  // evidence (loss60 capture, 2026-08-07): when a fresh dial succeeds it
  // does so in 4-10 s, and the profile's fate is decided by how many
  // independent handshake samples fit the budget — parallel samples
  // multiply the per-cycle odds. Each dial owns its HttpClient (a shared
  // pool serializes dials behind a stalled one — measured: 45 clockwork
  // dials, zero completions) and carries UNCONDITIONAL cleanup: dart:io
  // WebSocket.connect cannot be cancelled, so every non-winning dial —
  // late success, failure, or landing after the caller's own timeout
  // abandoned the race — force-closes its socket and client, or three
  // speculative handshakes per ~10 s cycle would accumulate unboundedly
  // (adversarial review finding, 2026-08-07).
  // Fan-out is CONDITIONAL: parallel handshakes multiply odds on a LOSSY
  // link (independent drop dice) but on a bandwidth-starved pipe they
  // compete for the same few kbit/s and starve each other — measured
  // 2026-08-07: narrow (16 kbit/s, zero loss) connected in 4-12 s with one
  // dial and exhausted its whole 57 s budget with three.
  final dialAttempts = (e2eShapedConditions.loss >= 0.3 &&
          e2eShapedConditions.bandwidthBps == null)
      ? 3
      : 1;
  return (Uri uri) async {
    final winner = Completer<_E2eIoSignalingSocket>();
    var resolved = false;
    var failures = 0;
    final attempts = dialAttempts;
    for (var i = 0; i < attempts; i++) {
      unawaited(
        Future<void>.delayed(Duration(milliseconds: 300 * i)).then((_) {
          if (resolved) return null;
          final client = newClient();
          return WebSocket.connect(uri.toString(), customClient: client)
              .timeout(const Duration(seconds: 9))
              .then((ws) {
            if (resolved) {
              unawaited(ws.close());
              client.close(force: true);
              return;
            }
            resolved = true;
            winner.complete(_E2eIoSignalingSocket(ws));
          }).catchError((Object error) {
            client.close(force: true);
            failures++;
            if (!resolved && failures == attempts && !winner.isCompleted) {
              resolved = true;
              winner.completeError(error);
            }
          });
        }),
      );
    }
    return winner.future;
  };
}

/// Minimal `dart:io` [SignalingSocket] (mirror of the app's private
/// `_IoSignalingSocket` in `call_session.dart`, which is not exported).
class _E2eIoSignalingSocket implements SignalingSocket {
  _E2eIoSignalingSocket(this._socket) {
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
        if (!_frames.isClosed) _frames.addError(error, stackTrace);
      },
      onDone: () {
        if (!_frames.isClosed) _frames.close();
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

// ---------------------------------------------------------------------------
// PER-OPERATION TIMEOUTS (adaptive, one model — 2026-08-06)
//
// One 15s constant used to bound three different operation classes inside
// CallController. The T2 matrix measured that as arithmetic failure, not
// flakiness: on `latency` (rtt 1800 ms) and `loss60` a single signaling
// send ('flush local ICE candidate', 'request ICE restart') exceeded 15s
// while the connect budget still had minutes left. The classes differ in
// round trips, so they get separate bounds, all derived from the SAME
// `AdaptiveConnectionBudget` model that already derives the connect budget.
// h2_run.sh passes the shaping conditions in E2E_RTT_MS / E2E_LOSS /
// E2E_BANDWIDTH_BPS; unset means pristine, and every getter floors at the
// old constant so unshaped in-process runs behave exactly as before.
//
//   class A  signaling-socket send-and-ack  -> e2eOperationTimeout
//            nominal 1 round trip, but the bound absorbs the worst
//            LEGITIMATE case: a liveness window to even notice a dead
//            socket, then TCP+TLS+WS re-establishment and the resent
//            frame's ack (5 round trips), on the model's retransmit and
//            serialization terms. (rtt 1800 ms broke the 15s bound with
//            zero loss — one clean round trip cannot do that; detection
//            plus re-establishment can.)
//   class B  media (re)connection wait      -> e2eConnectionTimeout
//            the full 8-round-trip ICE + DTLS + first-media handshake:
//            exactly one modelled attempt cost. The two channel-establish
//            _bounded sites (connect transport / start signaling) stay on
//            e2eOperationTimeout, whose model dominates their 5-round-trip
//            need on every profile (proven by the invariant script).
//   class C  local WebRTC engine calls      -> e2eEngineOperationTimeout
//            (createOffer/setLocalDescription/...): zero network, so the
//            bound is FIXED — a hung engine is a defect to detect fast on
//            every profile, not weather to wait out.
// ---------------------------------------------------------------------------
const int _e2eShapedRttMs = int.fromEnvironment('E2E_RTT_MS');
const String _e2eShapedLoss = String.fromEnvironment(
  'E2E_LOSS',
  defaultValue: '0',
);
const int _e2eShapedBandwidthBps = int.fromEnvironment('E2E_BANDWIDTH_BPS');

/// The shaped path's conditions as h2_run.sh configured them; pristine when
/// the suite runs without the rig.
final NetworkConditions e2eShapedConditions = NetworkConditions(
  rtt: const Duration(milliseconds: _e2eShapedRttMs),
  loss: double.tryParse(_e2eShapedLoss) ?? 0,
  bandwidthBps: _e2eShapedBandwidthBps > 0 ? _e2eShapedBandwidthBps : null,
);

final AdaptiveConnectionBudget _e2eBudget =
    AdaptiveConnectionBudget.fromConditions(e2eShapedConditions);

/// The constants these getters replaced. FLOORS, never targets: profiles
/// that pass at these bounds keep them (tightening a passing gate is a
/// separate, deliberate change); hostile profiles only ever raise.
const Duration _legacyOperationTimeout = Duration(seconds: 15);
const Duration _legacyConnectionTimeout = Duration(seconds: 20);

/// Round trips one signaling send may legitimately consume AFTER a dead
/// socket is detected: TCP (1) + TLS (2) + WS upgrade (1) + the resent
/// frame and its ack (1).
const int _signalingSendRoundTrips = 5;

/// Class A: one signaling-socket send-and-ack (offer / answer / candidate /
/// hangup / restart request). Nominal r = 1.
///
/// NO liveness detection floor since 2026-08-07. The floor existed so one
/// bound could absorb "notice the dead socket, re-establish, resend" — but
/// the outbox is at-least-once with a budget-spanning lifetime, so a
/// timed-out AWAIT abandons nothing (the envelope keeps retransmitting),
/// and the liveness timer tears dead sockets down on its own. Wire
/// evidence (loss60 signaling capture): fresh sockets deliver within
/// join-scale (~72 s) while the old 141 s bound spent most of its patience
/// waiting on a stream that was already dead — the shorter bound cycles to
/// a fresh socket at the cadence the wire actually rewards.
Duration get e2eOperationTimeout {
  final modelled = _e2eBudget.operationBudget(
    roundTrips: _signalingSendRoundTrips,
  );
  return modelled >= _legacyOperationTimeout
      ? modelled
      : _legacyOperationTimeout;
}

/// Class B: the media (re)connection wait, r = 8
/// ([AdaptiveConnectionBudget.handshakeRoundTrips]) — one full attempt.
Duration get e2eConnectionTimeout {
  final modelled = _e2eBudget.operationBudget(
    roundTrips: AdaptiveConnectionBudget.handshakeRoundTrips,
  );
  return modelled >= _legacyConnectionTimeout
      ? modelled
      : _legacyConnectionTimeout;
}

/// Class C: local engine calls, r = 0 — network-independent by design.
Duration get e2eEngineOperationTimeout => _legacyOperationTimeout;

/// Signaling keepalive timing: the historic aggressive constants are the
/// PRISTINE FLOORS (an unshaped in-process run behaves exactly as before);
/// on a shaped profile every value derives from the same conditions model as
/// the connect budget. Measured 2026-08-06 (loss60): the fixed 8 s liveness
/// window was routinely exceeded by ordinary TCP retransmit delay at 60%
/// per-direction loss, so a LIVE socket was declared dead nearly every
/// window and the reconnect + ICE-restart loop consumed the entire connect
/// budget — the run died in `phase=reconnecting` having never connected.
final SignalingClientConfig e2eSignalingConfig = () {
  final timing = _e2eBudget.signalingTiming(
    heartbeatFloor: const Duration(seconds: 2),
    livenessFloor: const Duration(seconds: 8),
    connectTimeoutFloor: const Duration(seconds: 10),
    reconnectAttemptsFloor: 5,
  );
  return SignalingClientConfig(
    heartbeatInterval: timing.heartbeatInterval,
    livenessTimeout: timing.livenessTimeout,
    initialReconnectDelay: const Duration(milliseconds: 100),
    maxReconnectDelay: const Duration(seconds: 1),
    maxReconnectAttempts: timing.maxReconnectAttempts,
    connectTimeout: timing.connectTimeout,
    outboxMessageLifetime: timing.messageLifetime,
    // HEDGED SOCKETS on heavy-loss profiles (raised 2026-08-09): one TCP
    // stream at 60% per-crossing loss stalls tens of seconds on
    // retransmission and serialized the whole negotiation ('send local
    // ICE candidate' timed out at 73 s while the socket lived). Two
    // extra sockets race every frame; the relay's multi-socket seat
    // fans inbound back to all; the client deduplicator drops copies.
    hedgeSockets: e2eShapedConditions.loss >= 0.3 ? 2 : 0,
  );
}();

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
  LoopbackRelay._(this.server, this.endpoint);

  /// Null when [e2eUsesRemoteRelay]: the relay is an external process on the
  /// Mac and its internals are not observable from here.
  final SignalingRelayServer? server;

  /// Where clients connect. In-process: `wss://localhost:<port>/`.
  /// Remote rig: the E2E_RELAY_URI define, verbatim.
  final Uri endpoint;

  static Future<LoopbackRelay> start() async {
    if (e2eUsesRemoteRelay) {
      print('e2e relay: REMOTE $e2eRelayUriOverride (no in-process server)');
      return LoopbackRelay._(null, Uri.parse(e2eRelayUriOverride));
    }
    final security = SecurityContext()
      ..useCertificateChainBytes(utf8.encode(e2eDevCertificatePem))
      ..usePrivateKeyBytes(utf8.encode(e2eDevPrivateKeyPem));
    final server = await SignalingRelayServer.bind(
      security: security,
      port: 0,
      abuseControls: e2eAbuseControls(),
    );
    return LoopbackRelay._(server, Uri.parse('wss://localhost:${server.port}/'));
  }

  Future<void> close() async {
    await server?.close();
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
  // Diagnostic override (2026-08-08): --dart-define=E2E_MEDIA_MODE=noLocalAudio
  // forces the fallback path WITHOUT touching the probe default. Added to
  // isolate whether real audio's wire cost is what kills the call on
  // bandwidth-starved rows (narrow died 3/3 with real audio; run 1 died
  // with ZERO lane bytes, so the lane is exonerated).
  const forced = String.fromEnvironment('E2E_MEDIA_MODE');
  if (forced == 'noLocalAudio') {
    _resolvedMode = MediaMode.noLocalAudio;
    _mediaModeReason = 'forced by E2E_MEDIA_MODE dart-define';
    return MediaMode.noLocalAudio;
  }
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
  } on TimeoutException {
    // A TIMEOUT is not a denial. A denied or unavailable microphone fails
    // FAST with an error; the only thing that makes getUserMedia hang for the
    // whole window is the TCC permission prompt sitting on screen with nobody
    // there to tap Allow. That is a PREREQUISITE of this install, not a media
    // failure, and it gets its own named line so an unattended harness can
    // report "grant the microphone once on this install, then re-run" instead
    // of a generic 30-second timeout. The run still continues honestly in
    // noLocalAudio below — the mode reporting is unchanged.
    _resolvedMode = MediaMode.noLocalAudio;
    _mediaModeReason =
        'getUserMedia(audio) timed out after ${probeTimeout.inSeconds}s '
        '(permission prompt pending?)';
    print(
      'E2E_PREREQ microphone: the permission prompt is pending on this '
      'install — grant it once on the device, then re-run',
    );
  } on Object catch (error) {
    _resolvedMode = MediaMode.noLocalAudio;
    _mediaModeReason = 'getUserMedia(audio) failed: $error';
  }
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

  /// The PRODUCT's adaptation loop, running on the test stack exactly as
  /// call_session.dart runs it in production (fidelity: threshold #3 judges
  /// the shipped stack, not a stripped one — the 2026-08-06 bandwidth FAIL
  /// measured a stack with the entire adaptation surgically absent).
  MediaAdaptationDriver? adaptationDriver;
  StreamSubscription<CallState>? _driverPhaseSub;

  /// Every applied adaptation decision, for the SLA summary's evidence
  /// fields — the row shows what the product DECIDED, not just what
  /// happened to it.
  final List<String> adaptationDecisionLog = [];

  /// Timestamped call-phase transitions since [build] — the anatomy of a
  /// failed connect, carried into timeout messages so a dead row explains
  /// itself instead of naming one final phase.
  final List<String> phaseLog = [];
  final DateTime _builtAt = DateTime.now();

  /// The last [n] phase transitions, one line.
  String recentPhases([int n = 14]) {
    final tail = phaseLog.length <= n
        ? phaseLog
        : phaseLog.sublist(phaseLog.length - n);
    return tail.join(' -> ');
  }

  /// One line per error, holding the exception type+code without the
  /// multi-line detail that would make the phase timeline unreadable.
  static String _briefError(Object error) {
    final s = error.toString();
    final line = s.split('\n').first;
    return line.length <= 90 ? line : '${line.substring(0, 87)}...';
  }

  factory E2eCallStack.build({
    required Uri endpoint,
    required String callId,
    required CallRole role,
    required MediaMode mode,
  }) {
    final client = SignalingClient(
      endpoint: endpoint,
      localKeyId: '${role.name}-key',
      connector: e2eWsConnector(endpoint),
      config: e2eSignalingConfig,
    );
    final gateway = SignalingClientGateway(client);
    final signalingAdapter = AdapterCallSignaling(gateway);
    late final E2eCallStack stack;
    // The link-derived audio budget, same model production uses
    // (call_session.dart): rate/ptime such that audio occupies at most 70%
    // of the known link, the rest reserved for the control plane. Unshaped
    // runs (no E2E_BANDWIDTH_BPS) derive the unconstrained default and the
    // policy below stays null — the historic behaviour.
    final wireAdmission = OpusWireBudget.forBandwidth(
      e2eShapedConditions.bandwidthBps,
      concurrentStreams: 2, // duplex: both mics share every crossing
    );
    // Same binding refusal as call_session.dart.
    final OpusWireBudget wireBudget = switch (wireAdmission) {
      OpusWireFitted(:final budget) => budget,
      OpusWireUnconstrained(:final budget) => budget,
      OpusWireNoCandidateFits() => throw CallAdmissionRefused(wireAdmission),
    };
    final constrainedLink = e2eShapedConditions.bandwidthBps != null;
    final media = WebRtcCallMediaSession(() async {
      final port = await FlutterWebRtcPeerConnectionPort.create(
        audio: mode == MediaMode.realAudio,
        iceServers: e2eIceServers(),
        // Gate 3c: the policy string comes from the same decision function
        // production uses, not from a shortcut. The environment flag now
        // feeds `iceProfileFor` through the manifest's own feature flags,
        // so the row exercises the production path instead of a parallel
        // one — a rig that proves a code path nobody ships proves nothing.
        iceTransportPolicy: e2eIceTransportPolicy(),
        opusPolicy: constrainedLink
            ? OpusSdpPolicy.forShapingState(
                fixedTickEmitterRunning: false,
                maxAverageBitrateBps: wireBudget.opusRateBps,
                ptimeMs: wireBudget.ptimeMs,
              )
            : null,
      ).timeout(const Duration(seconds: 10));
      stack.port = port;
      // Engine-layer wiretap (2026-08-09): envelope-level tracing proved
      // descriptions and remote candidates DELIVER, yet coturn saw zero
      // CreatePermission — the missing evidence is what the ICE engine
      // itself produces. Print every local candidate (its typ token says
      // relay/srflx/host) and every connection-status transition.
      port.localCandidates.listen((c) {
        final cand = c.candidate;
        final typIdx = cand.indexOf(' typ ');
        print(
          'e2e ${role.name} localCand: '
          '${typIdx < 0 ? cand : cand.substring(typIdx + 1)} '
          '@${DateTime.now().difference(stack._builtAt).inSeconds}s',
        );
      });
      port.connectionStatus.listen(
        (s) => print(
          'e2e ${role.name} pcStatus: $s '
          '@${DateTime.now().difference(stack._builtAt).inSeconds}s',
        ),
      );
      return port;
    },
    // Same seam as production (call_session.dart): the pure port contract
    // has no rollback, the Flutter port does. WITHOUT this the Dart layer
    // "rolls back" (signalingState := stable) while the NATIVE peer
    // connection stays in have-local-offer, and the next
    // setRemoteDescription(offer) dies with "Called in wrong state".
    // Hidden until 2026-08-07 because glare needed a receiver-side offer,
    // which only the initial-connect watchdog's recovery path produces —
    // the loss60 phase timeline showed the exact error twice.
    nativeRollback: (port) async {
      if (port is FlutterWebRtcPeerConnectionPort) {
        await port.rollbackLocalDescription();
      }
    });
    final controller = CallController(
      callId: callId,
      role: role,
      transport: AdapterCallTransport(gateway),
      signaling: signalingAdapter,
      media: media,
      // Recovery must survive at least a few full-length connect attempts.
      // The old maxElapsed of 5s was SMALLER than one bounded connect
      // attempt (operationTimeout = 15s): under heavy loss/latency the
      // first retry alone exceeded the elapsed cap, so the policy declined
      // after ~1 attempt and the call died with reconnect_exhausted ~30s
      // in. The next lesson (2026-08-06, loss60/extreme): a FIXED 100s
      // window was smaller than the harness's per-profile connect budget
      // (E2E_CONNECT_BUDGET_S, 300s on the hostile profiles), so the
      // policy exhausted while the test still had budget left. The window
      // now IS the connect budget — recovery (reconnect + ICE-restart
      // renegotiation, which also re-runs DTLS) survives exactly as long
      // as the harness is willing to wait, no longer and no shorter.
      // Twelve attempts with exponential backoff (0.5s -> 8s) fit that
      // window at the worst case (12 x (20s connect + 8s delay) > budget,
      // so maxElapsed is the binding cap on hostile profiles).
      reconnectPolicy: ExponentialBackoffReconnectPolicy(
        maxAttempts: 12,
        baseDelay: const Duration(milliseconds: 500),
        maxDelay: const Duration(seconds: 8),
        maxElapsed: const Duration(
          seconds: int.fromEnvironment(
            'E2E_CONNECT_BUDGET_S',
            defaultValue: 120,
          ),
        ),
      ),
      operationTimeout: e2eOperationTimeout,
      connectionTimeout: e2eConnectionTimeout,
      engineOperationTimeout: e2eEngineOperationTimeout,
    );
    stack = E2eCallStack._(
      role: role,
      client: client,
      signalingAdapter: signalingAdapter,
      media: media,
      controller: controller,
    );

    // Run the product's adaptation exactly as production wires it: sample
    // while connected, hold the profile across reconnects, cap every rung
    // at the link-derived ceiling.
    final driver = MediaAdaptationDriver(
      port: () => stack.port,
      audioCeilingBps: constrainedLink ? wireBudget.opusRateBps : null,
    );
    stack.adaptationDriver = driver;
    driver.decisions.listen(
      (d) => stack.adaptationDecisionLog.add(d.toString()),
    );
    // Live wiretap (2026-08-09): the loss60 hunt burned draws because the
    // only app-side evidence was the final phase name. Phases and every
    // deduped inbound envelope now print AS THEY HAPPEN, so one failed
    // draw's test.log names which leg of the exchange died (offer seen?
    // answer seen? candidate seen?) without another instrumented rerun.
    client.inbound.listen(
      (env) => print(
        'e2e ${role.name} in: ${env.type.name} room=${env.callId} '
        '@${DateTime.now().difference(stack._builtAt).inSeconds}s',
      ),
    );
    stack._driverPhaseSub = controller.states.listen((state) {
      // Phase timeline: on the hostile profiles the ONLY failure evidence
      // used to be the final phase name in the timeout message — one word
      // for a 231 s fight. Every transition is timestamped here so the
      // timeout message can carry the actual anatomy (silence -> evidence).
      final phaseLine =
          '${DateTime.now().difference(stack._builtAt).inSeconds}s '
          '${state.phase.name}'
          '${state.error == null ? '' : ' [${_briefError(state.error!)}]'}';
      print('e2e ${role.name} phase: $phaseLine');
      stack.phaseLog.add(phaseLine);
      if (state.phase == CallPhase.connected) {
        driver.start();
      } else {
        driver.stop();
        // Same wiring as production (call_session.dart): entering recovery
        // floors the sender immediately so the restart handshake owns the
        // constrained pipe instead of competing with live RTP.
        if (state.phase == CallPhase.reconnecting) {
          unawaited(driver.applySurvivalFloor());
        }
      }
    });

    // Room-join beacon: `SignalingRelayServer` pairs sockets purely by each
    // socket's FIRST frame's `callId` (relay_server.dart `_joinRoom`), and
    // neither `call_core` nor `signaling` has an explicit join primitive.
    // The initiator's first frame is naturally its SDP offer, but the
    // receiver has nothing to send until it decodes an inbound offer --
    // which it can only receive after already being in that room. (Since
    // 2026-08-09 the client's heartbeat carries the last app envelope's
    // room id — 'session' only before the first-ever send — so hedge and
    // promoted sockets pin to the CALL room too; this beacon remains the
    // deterministic first join for the receiver's fresh connect.) Enqueue
    // one no-op
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
    // Race `connected` against the controller's terminal future. Without
    // the `done` arm, a call that ends terminally (e.g. `failed` with
    // `reconnect_exhausted` after the signalling handshake exceeds the
    // operation timeout under heavy loss/latency) leaves this future
    // pending forever: `connected` can no longer occur, and only an outer
    // backstop ever fires — with no named reason. Terminal-first now
    // surfaces the controller's own endReason/error as a typed failure.
    return Future.any<CallState>([
      controller.states
          .firstWhere((state) => state.phase == CallPhase.connected),
      controller.done.then((state) {
        throw StateError(
          '${role.name} call ended before reaching connected: '
          'phase=${state.phase.name} '
          'endReason=${state.endReason?.name} '
          'error=${state.error}',
        );
      }),
    ]).timeout(
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
    await _driverPhaseSub?.cancel();
    await adaptationDriver?.dispose();
    await controller.dispose();
    await client.dispose();
  }
}

/// Polls the relay until [expected] rooms remain (server-side teardown runs
/// on its own event-loop turn after the client socket closes).
/// No-op (with a printed note) when the relay is remote: an external relay's
/// room table cannot be observed from the app process.
Future<void> waitForActiveRooms(
  SignalingRelayServer? server,
  int expected, {
  Duration timeout = const Duration(seconds: 3),
}) async {
  if (server == null) {
    print('waitForActiveRooms: remote relay — room count not observable');
    return;
  }
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

/// Closed-loop sentinel instrument («هوشمندی v4» pillar 2): runs the
/// SAME TrendMonitor the fabric acts on, fed once per second from the
/// live call's received-packet counter (delta normalized by the running
/// max — the replay benchmark's exact delivery proxy), and measures what
/// the prediction was worth:
///
/// - `sentinelLeadMs`: first failingSoon warning -> first post-connect
///   disconnect. Positive = the sentinel saw it coming. Negative or null
///   when it did not — recorded as measured, never invented.
/// - `preventedFreezes`: warnings whose 30 s window (the benchmark's
///   noise horizon) passed with NO disconnect — the projection said
///   trouble, the product's recovery loop acted, the freeze never came.
///   Windows truncated by call end are not counted (no over-claiming).
///
/// It also prints one machine line per sample —
///   `TREND {"t":…,"score":…,"slope":…,"proj":…,"verdict":…}`
/// — which pillar 6 harvests into the replay corpus, giving the trend
/// component its first trainable per-second signal (measured 2026-08-11:
/// on the packet-count-only corpus, 72 window/horizon/floor combos all
/// score raw 0.5735 — the richer signal is what unlocks learning).
class SentinelProbe {
  SentinelProbe({required this.port, required this.role});

  final FlutterWebRtcPeerConnectionPort port;
  final String role;

  final TrendMonitor _monitor = TrendMonitor();
  static const String _laneId = 'call';

  Timer? _timer;
  StreamSubscription<PeerConnectionStatus>? _statusSub;
  DateTime? _startedAt;
  int? _lastReceived;
  int _maxDelta = 0;
  bool _wasFailingSoon = false;

  DateTime? _firstConnectedAt;
  final List<int> _warnsMs = [];
  final List<int> _disconnectsMs = [];
  String? _firstGrounds;

  int _nowMs() => DateTime.now().difference(_startedAt!).inMilliseconds;

  /// Starts sampling. Call once the call is connected (or connecting —
  /// pre-connect samples simply see zero deltas and stay `unknown`).
  void start() {
    if (_timer != null) return;
    _startedAt = DateTime.now();
    _statusSub = port.connectionStatus.listen((s) {
      if (s == PeerConnectionStatus.connected) {
        _firstConnectedAt ??= DateTime.now();
      } else if (s == PeerConnectionStatus.disconnected ||
          s == PeerConnectionStatus.failed) {
        if (_firstConnectedAt != null) _disconnectsMs.add(_nowMs());
      }
    });
    _timer = Timer.periodic(const Duration(seconds: 1), (_) async {
      final t = _nowMs();
      int? received;
      try {
        final counters = await port
            .readStatsCounters()
            .timeout(const Duration(milliseconds: 900));
        received = counters?.packetsReceived;
      } catch (_) {
        received = null; // A slow stats poll is data (a stalling call).
      }
      final last = _lastReceived;
      if (received != null) _lastReceived = received;
      if (received == null || last == null) return;
      final delta = received - last;
      if (delta > _maxDelta) _maxDelta = delta;
      if (_maxDelta <= 0) return;
      _monitor.observe(_laneId, delta / _maxDelta, nowMs: t);
      final detail = _monitor.verdictDetail(_laneId);
      final e = detail.evidence;
      // Machine line for the corpus (pillar 6). ASCII, one per second.
      print(
        'TREND {"role":"$role","t":${t ~/ 1000}'
        ',"score":${(delta / _maxDelta).toStringAsFixed(4)}'
        ',"slope":${e.scoreSlopePerSec?.toStringAsFixed(5) ?? 'null'}'
        ',"proj":${e.projectedScore?.toStringAsFixed(4) ?? 'null'}'
        ',"verdict":"${detail.verdict.name}"}',
      );
      final failingSoon = detail.verdict == TrendVerdict.failingSoon;
      if (failingSoon && !_wasFailingSoon) {
        _warnsMs.add(t);
        _firstGrounds ??= detail.grounds;
      }
      _wasFailingSoon = failingSoon;
    });
  }

  /// Stops sampling and returns the measured summary fields.
  Map<String, Object?> stopAndReport() {
    _timer?.cancel();
    _timer = null;
    _statusSub?.cancel();
    final endMs = _startedAt == null ? 0 : _nowMs();
    // 30000 ms: the replay benchmark's noise horizon — a warning is
    // judged against exactly the window the benchmark judges.
    const windowMs = 30000;
    var prevented = 0;
    for (final warn in _warnsMs) {
      if (endMs - warn < windowMs) continue; // truncated window: no claim
      final freezeFollowed = _disconnectsMs.any(
        (d) => d > warn && d <= warn + windowMs,
      );
      if (!freezeFollowed) prevented += 1;
    }
    final firstWarn = _warnsMs.isEmpty ? null : _warnsMs.first;
    final firstDisconnect = _disconnectsMs.isEmpty
        ? null
        : _disconnectsMs.first;
    return {
      'sentinelWarns': _warnsMs.length,
      'sentinelLeadMs': firstWarn == null || firstDisconnect == null
          ? null
          : firstDisconnect - firstWarn,
      'preventedFreezes': prevented,
      'sentinelFirstGrounds': _firstGrounds,
    };
  }
}
