import 'dart:async';

import 'package:clock/clock.dart';

import 'call_state.dart';
import 'reconnect_policy.dart';
import 'validation.dart';

/// Which side of a call a [CallController] is acting as.
///
/// Only affects who initiates SDP negotiation and the "polite peer" rule in
/// [CallController._handleRemoteDescription] (the [receiver] never ignores
/// a colliding offer; the [initiator] does, per the standard WebRTC
/// perfect-negotiation pattern).
enum CallRole {
  /// Starts the call: sends the first SDP offer, and is the "impolite"
  /// peer during an offer collision (ignores an incoming offer instead of
  /// rolling back).
  initiator,

  /// Answers the call: waits for an SDP offer, and is the "polite" peer
  /// during an offer collision (rolls back its own in-flight offer to
  /// accept the incoming one instead).
  receiver,
}

/// Whether a [SessionDescription] is an SDP offer or answer.
enum SessionDescriptionType {
  /// A description sent by the negotiation-initiating side.
  offer,

  /// A description sent in response to an [offer].
  answer,
}

/// Mirrors the underlying media/PeerConnection's ICE + DTLS connectivity
/// state, as reported by a [CallMediaSession] through
/// [MediaConnectionChangedEvent].
///
/// [CallController] treats [disconnected] and [failed] as recoverable (they
/// trigger [CallController._beginRecovery]) and [closed] as also
/// recoverable but additionally marks the media session as needing a fresh
/// `start()` (`_mediaStarted` is reset) before the next attempt.
enum MediaConnectionState {
  /// No connection has been attempted yet.
  newConnection,

  /// ICE/DTLS negotiation is in progress.
  connecting,

  /// The media path is connected. Triggers [CallPhase.connected] and clears
  /// any in-progress recovery.
  connected,

  /// The connection dropped but may recover without a full renegotiation
  /// (e.g. a transient ICE hiccup). Triggers recovery.
  disconnected,

  /// The connection failed outright and needs an ICE restart to recover.
  /// Triggers recovery.
  failed,

  /// The underlying connection object was closed. Triggers recovery and
  /// requires the media session to be restarted.
  closed,
}

/// Mirrors the underlying media/PeerConnection's SDP signaling state (the
/// offer/answer exchange sub-state), as reported by a [CallMediaSession].
///
/// Read by [CallController._handleRemoteDescription] and
/// [CallController._negotiate] to detect an offer collision (not [stable])
/// and to decide whether an incoming answer is actually expected
/// ([haveLocalOffer]).
enum MediaSignalingState {
  /// No offer/answer exchange is in flight; a new offer may be created.
  stable,

  /// A local offer has been set and an answer is awaited.
  haveLocalOffer,

  /// A remote offer has been set and a local answer has not been sent yet.
  haveRemoteOffer,

  /// The underlying connection's signaling machinery has been shut down.
  closed,
}

/// The health of the signaling channel, as reported by a [CallTransport]
/// through [TransportEvent].
///
/// This is deliberately coarser than whatever connection states the
/// concrete transport implementation exposes internally — [CallController]
/// only needs to know "is the channel usable right now," not the
/// implementation's own reconnect sub-states.
enum TransportStatus {
  /// The transport is attempting to establish (or re-establish) a
  /// connection. Not treated as a failure by [CallController].
  connecting,

  /// The transport is connected and usable.
  connected,

  /// The transport lost its connection. Triggers
  /// [CallController._beginRecovery].
  disconnected,

  /// The transport was closed and will not reconnect on its own. Triggers
  /// [CallController._beginRecovery].
  closed,
}

/// A validated SDP offer or answer, as produced by [CallMediaSession] and
/// carried over [CallSignaling]/[CallTransport].
///
/// Validation is deliberately shallow (non-empty, bounded length, starts
/// with a `v=0` line) — this is a transport-safety check against garbage or
/// oversized payloads, not an SDP grammar validator; the media layer is
/// responsible for the SDP actually being well-formed.
final class SessionDescription {
  /// Creates a description. Throws [ArgumentError] if [sdp] is empty,
  /// longer than 1 MiB, or does not start with a `v=0` line.
  SessionDescription({required this.type, required this.sdp}) {
    if (sdp.isEmpty || sdp.length > 1024 * 1024) {
      throw ArgumentError.value(sdp.length, 'sdp.length');
    }
    if (!sdp.trimLeft().startsWith('v=0')) {
      throw ArgumentError.value(
        '<redacted>',
        'sdp',
        'SDP must begin with a v=0 line',
      );
    }
  }

  /// Whether this is an [SessionDescriptionType.offer] or
  /// [SessionDescriptionType.answer].
  final SessionDescriptionType type;

  /// The raw SDP text.
  final String sdp;
}

/// A validated ICE candidate (or an end-of-candidates marker), as produced
/// by [CallMediaSession] and carried over [CallSignaling]/[CallTransport].
///
/// [candidate] is nullable to represent the standard "end of candidates"
/// signal used by trickle ICE; every other field's validity depends on
/// whether [candidate] is null (see each field's doc).
final class IceCandidate {
  /// Creates a candidate. Throws [ArgumentError] if:
  /// - [candidate] is non-null but empty, longer than 16 KiB, contains a
  ///   line break, or does not start with `candidate:`;
  /// - [candidate] is non-null and neither [sdpMid] nor [sdpMLineIndex] is
  ///   set;
  /// - [sdpMid] is non-null but empty or longer than 256 characters;
  /// - [sdpMLineIndex] is non-null and negative.
  IceCandidate({required this.candidate, this.sdpMid, this.sdpMLineIndex}) {
    final value = candidate;
    if (value != null) {
      if (value.isEmpty || value.length > 16 * 1024) {
        throw ArgumentError.value(value.length, 'candidate.length');
      }
      if (value.contains('\r') || value.contains('\n')) {
        throw ArgumentError.value(
          '<redacted>',
          'candidate',
          'ICE candidates must be a single line',
        );
      }
      if (!value.startsWith('candidate:')) {
        throw ArgumentError.value(
          '<redacted>',
          'candidate',
          'ICE candidate must begin with candidate:',
        );
      }
      if (sdpMid == null && sdpMLineIndex == null) {
        throw ArgumentError(
          'A non-null candidate requires sdpMid or sdpMLineIndex',
        );
      }
    }
    if (sdpMid != null && (sdpMid!.isEmpty || sdpMid!.length > 256)) {
      throw ArgumentError.value(sdpMid, 'sdpMid');
    }
    if (sdpMLineIndex != null && sdpMLineIndex! < 0) {
      throw ArgumentError.value(sdpMLineIndex, 'sdpMLineIndex');
    }
  }

  /// The candidate string (starting with `candidate:`), or `null` for the
  /// standard trickle-ICE "end of candidates" marker.
  final String? candidate;

  /// The media stream identification tag this candidate belongs to.
  /// Required (together with, or instead of, [sdpMLineIndex]) whenever
  /// [candidate] is non-null.
  final String? sdpMid;

  /// The zero-based m-line index this candidate belongs to. Required
  /// (together with, or instead of, [sdpMid]) whenever [candidate] is
  /// non-null.
  final int? sdpMLineIndex;
}

/// Events a [CallMediaSession] pushes up to [CallController] about the
/// local media/PeerConnection.
sealed class MediaEvent {
  const MediaEvent();
}

/// A local ICE candidate was gathered and should be sent to the remote
/// peer. [CallController] forwards it over [CallSignaling] immediately if
/// the signaling channel is up, or buffers it (see
/// `CallController._bufferLocalCandidate`) to flush once it is.
final class LocalIceCandidateEvent extends MediaEvent {
  const LocalIceCandidateEvent(this.candidate);

  /// The gathered candidate.
  final IceCandidate candidate;
}

/// The media session's [MediaConnectionState] changed.
final class MediaConnectionChangedEvent extends MediaEvent {
  const MediaConnectionChangedEvent(this.state, {this.error});

  /// The new connection state.
  final MediaConnectionState state;

  /// The underlying cause, if the media/adapter layer has one. When null on
  /// a state that [CallController] treats as a failure, the controller
  /// synthesizes a [CallControllerException] describing the state itself
  /// (see the `media_<state>` / `media_closed` codes on
  /// [CallControllerException.code]).
  final Object? error;
}

/// The media session hit an unrecoverable-by-itself error unrelated to a
/// specific [MediaConnectionState] transition (e.g. an internal exception
/// while gathering candidates). Always triggers
/// `CallController._beginRecovery`.
final class MediaFailureEvent extends MediaEvent {
  const MediaFailureEvent(this.error, [this.stackTrace]);

  /// The underlying cause.
  final Object error;

  /// The stack trace at the point [error] was raised, if available.
  final StackTrace? stackTrace;
}

/// A [CallTransport]'s current [TransportStatus].
final class TransportEvent {
  const TransportEvent(this.status, {this.error});

  /// The transport's current status.
  final TransportStatus status;

  /// The underlying cause, if the transport layer has one. When null on a
  /// status [CallController] treats as a failure, the controller
  /// synthesizes a [CallControllerException] describing the status itself
  /// (see the `transport_<status>` codes on
  /// [CallControllerException.code]).
  final Object? error;
}

/// Events a [CallSignaling] implementation pushes up to [CallController]
/// about messages received from the remote peer (or about the signaling
/// channel itself).
sealed class SignalingEvent {
  const SignalingEvent();
}

/// The remote peer sent an SDP offer or answer.
final class RemoteDescriptionEvent extends SignalingEvent {
  const RemoteDescriptionEvent(this.description);

  /// The received description.
  final SessionDescription description;
}

/// The remote peer sent an ICE candidate (or an end-of-candidates marker).
final class RemoteIceCandidateEvent extends SignalingEvent {
  const RemoteIceCandidateEvent(this.candidate);

  /// The received candidate.
  final IceCandidate candidate;
}

/// The remote peer hung up. Drives the call straight to
/// [CallEndReason.remoteHangup] via `CallController._finishEnded`.
final class RemoteHangupEvent extends SignalingEvent {
  /// Creates the event. Throws [ArgumentError] if [reason] is longer than
  /// 256 characters or contains a control character
  /// ([containsControlCharacters]).
  RemoteHangupEvent([this.reason]) {
    final value = reason;
    if (value != null &&
        (value.length > 256 || containsControlCharacters(value))) {
      throw ArgumentError.value(value, 'reason');
    }
  }

  /// The peer-supplied reason for the hangup, if any.
  final String? reason;
}

/// The remote peer requested an ICE restart. [CallController] runs
/// `CallController._negotiate` with `iceRestart: true` in response (only
/// if signaling is currently started).
final class RestartRequestedEvent extends SignalingEvent {
  const RestartRequestedEvent();
}

/// The signaling implementation hit an error unrelated to a specific
/// message (e.g. a malformed inbound payload it could not decode). Always
/// triggers `CallController._beginRecovery`.
final class SignalingFailureEvent extends SignalingEvent {
  const SignalingFailureEvent(this.error, [this.stackTrace]);

  /// The underlying cause.
  final Object error;

  /// The stack trace at the point [error] was raised, if available.
  final StackTrace? stackTrace;
}

/// Commands [CallController] issues down to a [CallSignaling]
/// implementation, to be relayed to the remote peer.
sealed class SignalingCommand {
  const SignalingCommand();
}

/// Send an SDP offer or answer to the remote peer.
final class SendDescriptionCommand extends SignalingCommand {
  const SendDescriptionCommand(this.description);

  /// The description to send.
  final SessionDescription description;
}

/// Send a local ICE candidate (or an end-of-candidates marker) to the
/// remote peer.
final class SendIceCandidateCommand extends SignalingCommand {
  const SendIceCandidateCommand(this.candidate);

  /// The candidate to send.
  final IceCandidate candidate;
}

/// Tell the remote peer this side is hanging up.
final class SendHangupCommand extends SignalingCommand {
  /// Creates the command. Throws [ArgumentError] if [reason] is longer than
  /// 256 characters or contains a control character
  /// ([containsControlCharacters]).
  SendHangupCommand([this.reason]) {
    final value = reason;
    if (value != null &&
        (value.length > 256 || containsControlCharacters(value))) {
      throw ArgumentError.value(value, 'reason');
    }
  }

  /// The peer-supplied reason for the hangup, if any.
  final String? reason;
}

/// Ask the remote peer to initiate an ICE restart (sent by the [receiver]
/// side when it needs to recover but is not the one who negotiates).
final class SendRestartRequestCommand extends SignalingCommand {
  const SendRestartRequestCommand();
}

/// The signaling-channel transport a [CallController] rides on.
///
/// Deliberately narrow: [CallController] only needs to know whether the
/// channel is up, not how it got that way — reconnect logic for the
/// channel itself (if any) belongs to the implementation, which reports
/// its result through [TransportStatus] rather than the reconnect
/// machinery [CallController] runs for the *call*.
abstract interface class CallTransport {
  /// Status changes for this transport. [CallController] treats
  /// [TransportStatus.disconnected] and [TransportStatus.closed] as
  /// recoverable failures.
  Stream<TransportEvent> get events;

  /// Establishes (or re-establishes) the connection. Called once by
  /// `CallController.start` and again at the top of every recovery attempt.
  Future<void> connect();

  /// Tears down the connection. Called during teardown/recovery-reset;
  /// implementations should make this safe to call even if [connect] never
  /// succeeded.
  Future<void> disconnect();
}

/// The call-signaling protocol a [CallController] uses to exchange SDP,
/// ICE candidates, and control messages ([SignalingCommand]) with the
/// remote peer.
abstract interface class CallSignaling {
  /// Messages received from the remote peer, or channel-level failures.
  Stream<SignalingEvent> get events;

  /// Joins the signaling channel for [callId] as [role]. Called once by
  /// `CallController.start` and again (with the same [callId]/[role]) at
  /// the top of every recovery attempt.
  Future<void> start({required String callId, required CallRole role});

  /// Sends [command] to the remote peer over the signaling channel.
  Future<void> send(SignalingCommand command);

  /// Leaves the signaling channel. Called during teardown/recovery-reset.
  Future<void> stop();
}

/// The local media/PeerConnection layer a [CallController] drives.
///
/// [CallController] never reaches into WebRTC internals directly — every
/// SDP/ICE operation goes through this interface, so the underlying media
/// stack (real WebRTC, a test fake, a future non-WebRTC transport) is
/// fully swappable.
abstract interface class CallMediaSession {
  /// Local ICE candidates, connection-state changes, and session-level
  /// failures.
  Stream<MediaEvent> get events;

  /// The current [MediaConnectionState], read synchronously (not just via
  /// [events]) by [CallController] to decide whether a recovery attempt
  /// already succeeded before its connection-timeout timer fires.
  MediaConnectionState get connectionState;

  /// The current [MediaSignalingState], read synchronously to detect an
  /// offer collision and to validate that an incoming answer is actually
  /// expected.
  MediaSignalingState get signalingState;

  /// Starts the underlying media session. Called once by
  /// `CallController.start` and again (if needed) at the top of every
  /// recovery attempt.
  Future<void> start();

  /// Creates a local SDP offer. [iceRestart] requests a fresh ICE
  /// generation for recovery; the returned description's
  /// [SessionDescription.type] must be [SessionDescriptionType.offer].
  Future<SessionDescription> createOffer({required bool iceRestart});

  /// Creates a local SDP answer in response to a remote offer. The
  /// returned description's [SessionDescription.type] must be
  /// [SessionDescriptionType.answer].
  Future<SessionDescription> createAnswer();

  /// Applies [description] (this side's own offer/answer) to the local
  /// session.
  Future<void> setLocalDescription(SessionDescription description);

  /// Applies [description] (the remote peer's offer/answer) to the local
  /// session.
  Future<void> setRemoteDescription(SessionDescription description);

  /// Adds a remote ICE candidate (or applies an end-of-candidates marker)
  /// received over signaling.
  Future<void> addRemoteIceCandidate(IceCandidate candidate);

  /// Reverts an in-flight local offer, e.g. to accept a colliding remote
  /// offer or before issuing an ICE-restart offer while not [stable]
  /// ([MediaSignalingState.stable]).
  Future<void> rollback();

  /// Stops the underlying media session. Called during
  /// teardown/recovery-reset.
  Future<void> stop();
}

/// The base exception type for [CallController] failures, carrying a
/// stable machine-readable [code] alongside the human-readable [message].
///
/// The full set of [code] values used by [CallController] itself:
/// `protocol_error` (via [CallProtocolException]), `transport_<status>`
/// (`transport_disconnected`, `transport_closed`),
/// `transport_stream_closed`, `signaling_stream_closed`,
/// `media_<state>` (`media_disconnected`, `media_failed`), `media_closed`,
/// `media_stream_closed`, `invalid_reconnect_policy`,
/// `reconnect_exhausted`, `reconnect_connection_timeout`, `path_unhealthy`
/// (the default cause of an external `requestRecovery`). A caller matching
/// on [code] should treat this list as non-exhaustive — new codes may be
/// added without a breaking change.
final class CallControllerException implements Exception {
  const CallControllerException(this.code, this.message, {this.cause});

  /// A stable, machine-readable identifier for the failure. See the class
  /// doc for the full set of values [CallController] itself produces.
  final String code;

  /// A human-readable description of the failure.
  final String message;

  /// The underlying error that triggered this exception, if any.
  final Object? cause;

  @override
  String toString() => 'CallControllerException($code): $message';
}

/// The remote peer (or a media adapter) violated the negotiation protocol
/// — e.g. [CallMediaSession.createAnswer] returned something that isn't an
/// answer. Always carries [CallControllerException.code] `protocol_error`
/// and drives the call straight to [CallEndReason.protocolError] via
/// `CallController._fail` (never enters the reconnect loop).
final class CallProtocolException extends CallControllerException {
  const CallProtocolException(String message, {Object? cause})
    : super('protocol_error', message, cause: cause);
}

/// Platform-independent orchestration of one call's lifecycle: connecting
/// the transport/signaling/media layers, SDP offer/answer negotiation
/// (including perfect-negotiation collision handling), ICE candidate
/// buffering, automatic recovery with a pluggable [ReconnectPolicy], and
/// graceful/abnormal termination — all exposed as a single [CallState]
/// stream ([states]).
///
/// Every method that mutates controller state (`start`, `hangUp`,
/// `dispose`, and every internal event handler) runs through a single
/// serial task queue (`_enqueue`), so the controller never processes two
/// operations concurrently — callers do not need to add their own locking.
///
/// Lifecycle: construct → [start] (exactly once) → zero or more automatic
/// recovery cycles → a terminal [CallState] ([CallPhase.ended] or
/// [CallPhase.failed]), reachable either on its own (remote hangup,
/// protocol error, reconnect exhaustion) or by calling [hangUp]. [dispose]
/// may be called at any point (including before [start], and safely more
/// than once) to force teardown and release all resources; it always ends
/// with the [states] stream closed.
final class CallController {
  /// Creates a controller for one call. Does not connect anything —
  /// nothing happens over the network until [start] is called.
  ///
  /// Throws [ArgumentError] if [callId] is empty, longer than 128
  /// characters, or contains characters outside `[A-Za-z0-9._~-]`; if
  /// [operationTimeout], [connectionTimeout], or [engineOperationTimeout]
  /// is not positive; or if [maxBufferedIceCandidates] is outside
  /// `1..4096`.
  CallController({
    required String callId,
    required this.role,
    required this.transport,
    required this.signaling,
    required this.media,
    required this.reconnectPolicy,
    this.operationTimeout = const Duration(seconds: 15),
    this.connectionTimeout = const Duration(seconds: 20),
    this.engineOperationTimeout = const Duration(seconds: 15),
    this.mediaStartTimeout = const Duration(seconds: 30),
    this.maxBufferedIceCandidates = 256,
  }) : callId = _validateCallId(callId),
       _state = CallState(
         phase: CallPhase.idle,
         sequence: 0,
         changedAt: clock.now().toUtc(),
       ) {
    if (operationTimeout <= Duration.zero) {
      throw ArgumentError.value(operationTimeout, 'operationTimeout');
    }
    if (connectionTimeout <= Duration.zero) {
      throw ArgumentError.value(connectionTimeout, 'connectionTimeout');
    }
    if (engineOperationTimeout <= Duration.zero) {
      throw ArgumentError.value(
        engineOperationTimeout,
        'engineOperationTimeout',
      );
    }
    if (mediaStartTimeout <= Duration.zero) {
      throw ArgumentError.value(mediaStartTimeout, 'mediaStartTimeout');
    }
    if (maxBufferedIceCandidates < 1 || maxBufferedIceCandidates > 4096) {
      throw ArgumentError.value(
        maxBufferedIceCandidates,
        'maxBufferedIceCandidates',
      );
    }
  }

  /// The validated call identifier shared with the remote peer via
  /// [CallSignaling.start].
  final String callId;

  /// Which side of the call this controller acts as. See [CallRole].
  final CallRole role;

  /// The signaling-channel transport. See [CallTransport].
  final CallTransport transport;

  /// The call-signaling protocol implementation. See [CallSignaling].
  final CallSignaling signaling;

  /// The local media/PeerConnection layer. See [CallMediaSession].
  final CallMediaSession media;

  /// Decides whether/when to retry after a channel or media failure. See
  /// [ReconnectPolicy].
  final ReconnectPolicy reconnectPolicy;

  /// The per-operation timeout applied to every awaited NETWORK call into
  /// [transport] and [signaling] (via `CallController._bounded`). An
  /// operation that exceeds this fails with a [TimeoutException], which is
  /// then handled the same as any other failure from that layer. On a
  /// shaped or hostile path this should scale with the path's round-trip
  /// time and loss (see `AdaptiveConnectionBudget.operationBudget`); calls
  /// into [media] are engine-local and bounded by [engineOperationTimeout]
  /// instead.
  final Duration operationTimeout;

  /// The timeout applied to every awaited COMPUTE call into [media]
  /// (createOffer, createAnswer, set*Description, rollback,
  /// addRemoteIceCandidate, stop — via `CallController._boundedEngine`).
  /// These touch no network, so this bound is deliberately FIXED and
  /// independent of path conditions: a hung engine is a defect to detect
  /// fast on every profile, not weather to wait out.
  ///
  /// [CallMediaSession.start] is NOT in this class — see
  /// [mediaStartTimeout].
  final Duration engineOperationTimeout;

  /// The timeout for [CallMediaSession.start] alone. Start contains
  /// `getUserMedia`, whose latency is HUMAN, not compute: on a fresh
  /// install the OS permission prompt sits on screen until a person
  /// answers it. Bounding that wait with the 15 s engine bound severed
  /// the first call of every fresh install while the mic prompt was
  /// still up; 30 s matches the documented TCC-prompt rationale in the
  /// e2e harness. A wedged native stack now takes 30 s to classify on
  /// start — the accepted price for not hanging up on a human reading a
  /// dialog.
  final Duration mediaStartTimeout;

  /// How long a recovery attempt waits for [media]'s
  /// [CallMediaSession.connectionState] to report
  /// [MediaConnectionState.connected] before giving up and scheduling
  /// another attempt (see `CallController._performRecoveryAttempt`).
  final Duration connectionTimeout;

  /// The maximum number of not-yet-sendable local ICE candidates buffered
  /// while the signaling channel is down. Once exceeded, the OLDEST
  /// buffered candidate is dropped to make room for the newest (see
  /// `CallController._bufferLocalCandidate`) — an at-most-N sliding window,
  /// not a hard cap that rejects new candidates.
  final int maxBufferedIceCandidates;

  final StreamController<CallState> _stateController =
      StreamController<CallState>.broadcast(sync: true);
  final Completer<CallState> _doneCompleter = Completer<CallState>();
  final List<StreamSubscription<Object?>> _subscriptions =
      <StreamSubscription<Object?>>[];
  final List<IceCandidate> _pendingLocalCandidates = <IceCandidate>[];

  /// Remote candidates the engine refused, PARKED for the next remote
  /// description. The at-least-once outbox acks on delivery, not on
  /// application, so a refused candidate is never re-sent by the far
  /// side — the receiver is the only place it can survive. Measured
  /// 2026-08-09 (loss60, hedged sockets): a ~300B candidate overtakes
  /// its multi-KB offer, the engine rejects it (no remote description
  /// yet), and dropping it left the forced-relay generation with ZERO
  /// remote candidates — no permission, no checks, an unconnectable
  /// draw that looked merely slow. Same drop-oldest window as the
  /// local buffer ([maxBufferedIceCandidates]).
  final List<IceCandidate> _pendingRemoteCandidates = <IceCandidate>[];

  late CallState _state;
  Future<void> _serialTail = Future<void>.value();

  bool _started = false;
  bool _disposed = false;
  bool _terminal = false;
  bool _subscriptionsInstalled = false;
  bool _mediaStarted = false;
  bool _signalingStarted = false;
  bool _makingOffer = false;
  bool _ignoreOffer = false;
  bool _suppressChannelEvents = false;
  bool _recoveryActive = false;
  bool _recoveryAttemptInFlight = false;
  bool _waitingForConnection = false;

  int _sequence = 0;
  int _recoveryAttempt = 0;
  DateTime? _recoveryStartedAt;
  Object? _lastRecoveryCause;
  Timer? _recoveryTimer;
  Timer? _initialConnectTimer;

  /// When the CURRENT initial-connect negotiation attempt began — the
  /// age baseline for the progress-patience cap (see the watchdog).
  DateTime? _initialAttemptStartedAt;

  /// When recovery last ran a HARD cycle (fresh channels + ICE restart)
  /// — the age baseline for recovery's progress-patience cap, the same
  /// "mere arrival is not completion" rule the initial watchdog enforces
  /// (its 2026-08-09 raise). Without it, mutual signaling chatter kept
  /// every recovery attempt in the progressing skip and no fresh TURN
  /// gathering ever started (measured 2026-08-09, loss60: two full 450s
  /// draws, TWO gathering source ports total, zero connects).
  DateTime? _recoveryHardCycleAt;

  /// Grace timer for a media `disconnected` squall — see the handler.
  Timer? _mediaDisconnectGraceTimer;

  /// When the far side last demonstrably delivered a signaling frame
  /// (description / candidate / restart request). Soft send-timeouts use
  /// this to distinguish a SLOW-BUT-ADVANCING negotiation from a silent
  /// one — only silence justifies cycling the socket (see _beginRecovery).
  DateTime? _lastRemoteSignalAt;

  /// Whether this call has EVER reached connected. The progress-aware
  /// patience below applies only to the INITIAL connect: once a call has
  /// been up, a recovery is about a path that already proved itself and
  /// then died — recent signaling chatter must not soften that cycle
  /// (path-health recovery on a connected call always hard-cycles).
  bool _everConnected = false;

  /// Every [CallState] this controller emits, in emission order
  /// ([CallState.sequence] strictly increasing). A broadcast stream that
  /// closes once [dispose] finishes.
  Stream<CallState> get states => _stateController.stream;

  /// The most recently emitted [CallState] (starts at [CallPhase.idle]
  /// before [start] is called).
  CallState get state => _state;

  /// Resolves with the final [CallState] once the call reaches a terminal
  /// phase ([CallPhase.ended] or [CallPhase.failed]).
  Future<CallState> get done => _doneCompleter.future;

  /// Begins the call: starts [media], connects [transport] and
  /// [signaling], and — if [role] is [CallRole.initiator] — sends the
  /// initial SDP offer. May only be called once per controller (a second
  /// call throws [StateError]); any failure along the way routes into the
  /// normal recovery loop rather than rethrowing from this [Future].
  ///
  /// Throws [StateError] if called more than once or after [dispose].
  Future<void> start() {
    return _enqueue<void>(() async {
      _ensureNotDisposed();
      if (_started) {
        throw StateError('CallController.start may only be called once');
      }

      _started = true;
      _emit(CallPhase.connecting);
      _installSubscriptions();

      try {
        await _ensureMediaStarted();
        await _connectChannels();
        _emit(CallPhase.negotiating);
        _armInitialConnectWatchdog();

        if (role == CallRole.initiator) {
          await _negotiate(iceRestart: false);
        }
      } catch (error, stackTrace) {
        await _beginRecovery(error, stackTrace);
      }
    });
  }

  /// Ends the call gracefully with [CallEndReason.localHangup]: best-effort
  /// notifies the remote peer (a failure to send is swallowed — the local
  /// side still hangs up), then tears everything down. A no-op if the call
  /// is already terminal.
  ///
  /// Throws [ArgumentError] (via the returned [Future]) if [reason] is
  /// empty, longer than 256 characters, or contains a control character
  /// ([containsControlCharacters]).
  Future<void> hangUp({String reason = 'hangup'}) {
    if (reason.isEmpty ||
        reason.length > 256 ||
        containsControlCharacters(reason)) {
      return Future<void>.error(ArgumentError.value(reason, 'reason'));
    }

    return _enqueue<void>(() async {
      _ensureNotDisposed();
      if (_terminal) {
        return;
      }

      _emit(CallPhase.ending);
      if (_signalingStarted) {
        await _bestEffort(
          () => _bounded(
            signaling.send(SendHangupCommand(reason)),
            'send hangup',
          ),
        );
      }

      await _finishEnded(CallEndReason.localHangup);
    });
  }

  /// Asks the controller to run its normal recovery loop (reconnect with
  /// backoff, then ICE-restart renegotiation) even though no channel has
  /// reported a failure yet — the seam for an external path-health monitor
  /// that scored the active network path unhealthy before transport or
  /// media noticed a hard drop.
  ///
  /// A no-op before [start], after a terminal phase, or after [dispose]:
  /// external monitors race teardown, so lifecycle mismatches never throw.
  /// Requests made while a recovery cycle is already active coalesce into
  /// it exactly like internal failure events.
  Future<void> requestRecovery({Object? cause}) {
    final effectiveCause =
        cause ??
        const CallControllerException(
          'path_unhealthy',
          'External path-health monitor scored the active path unhealthy',
        );
    return _enqueue<void>(() async {
      if (_disposed || _terminal || !_started) {
        return;
      }
      await _beginRecovery(effectiveCause, StackTrace.current);
    });
  }

  /// Marks the live call as running in survival [mode]
  /// ([CallPhase.degraded]) — called by an external quality driver when the
  /// path can no longer carry normal media. The call stays fully alive.
  ///
  /// Legal only while the call is live ([CallPhase.connected] or already
  /// degraded — re-entering with a different [mode] re-emits). A no-op in
  /// any other phase, after a terminal state, or after [dispose]: quality
  /// drivers race teardown, so lifecycle mismatches never throw.
  Future<void> enterDegradedMode(DegradedMode mode) {
    return _enqueue<void>(() async {
      if (_disposed || _terminal || !_started) {
        return;
      }
      final phase = _state.phase;
      if (phase != CallPhase.connected && phase != CallPhase.degraded) {
        return;
      }
      if (_state.degradedMode == mode) {
        return;
      }
      _emit(CallPhase.degraded, degradedMode: mode);
    });
  }

  /// Returns a degraded call to normal [CallPhase.connected] once the
  /// path can carry regular media again. A no-op unless the call is
  /// currently degraded.
  Future<void> exitDegradedMode() {
    return _enqueue<void>(() async {
      if (_disposed || _terminal || !_started) {
        return;
      }
      if (_state.phase != CallPhase.degraded) {
        return;
      }
      _emit(CallPhase.connected);
    });
  }

  /// Releases this controller's resources: tears down every channel (if
  /// not already terminal, ending the call with [CallEndReason.disposed]
  /// first), cancels all subscriptions, and closes [states]. Safe to call
  /// at any point in the lifecycle — before [start], mid-call, after a
  /// terminal state — and safe to call more than once (subsequent calls
  /// are a no-op).
  Future<void> dispose() {
    return _enqueue<void>(() async {
      if (_disposed) {
        return;
      }

      if (!_terminal) {
        if (_started) {
          _emit(CallPhase.ending);
        }
        await _finishEnded(CallEndReason.disposed);
      } else {
        _cancelSubscriptions();
      }

      _disposed = true;
      await _stateController.close();
    });
  }

  void _installSubscriptions() {
    if (_subscriptionsInstalled) {
      throw StateError('Subscriptions are already installed');
    }
    _subscriptionsInstalled = true;

    _subscriptions.add(
      transport.events.listen(
        (event) {
          final suppressed = _suppressChannelEvents;
          _enqueueEvent(() => _handleTransportEvent(event, suppressed));
        },
        onError: (Object error, StackTrace stackTrace) {
          final suppressed = _suppressChannelEvents;
          _enqueueEvent(
            () => _handleChannelStreamError(error, stackTrace, suppressed),
          );
        },
        onDone: () {
          final suppressed = _suppressChannelEvents;
          _enqueueEvent(
            () => _handleChannelStreamError(
              const CallControllerException(
                'transport_stream_closed',
                'Transport event stream closed unexpectedly',
              ),
              StackTrace.current,
              suppressed,
            ),
          );
        },
      ),
    );

    _subscriptions.add(
      signaling.events.listen(
        (event) => _enqueueEvent(() => _handleSignalingEvent(event)),
        onError: (Object error, StackTrace stackTrace) {
          final suppressed = _suppressChannelEvents;
          _enqueueEvent(
            () => _handleChannelStreamError(error, stackTrace, suppressed),
          );
        },
        onDone: () {
          final suppressed = _suppressChannelEvents;
          _enqueueEvent(
            () => _handleChannelStreamError(
              const CallControllerException(
                'signaling_stream_closed',
                'Signaling event stream closed unexpectedly',
              ),
              StackTrace.current,
              suppressed,
            ),
          );
        },
      ),
    );

    _subscriptions.add(
      media.events.listen(
        (event) => _enqueueEvent(() => _handleMediaEvent(event)),
        onError: (Object error, StackTrace stackTrace) {
          _enqueueEvent(() => _beginRecovery(error, stackTrace));
        },
        onDone: () {
          _enqueueEvent(
            () => _beginRecovery(
              const CallControllerException(
                'media_stream_closed',
                'Media event stream closed unexpectedly',
              ),
              StackTrace.current,
            ),
          );
        },
      ),
    );
  }

  Future<void> _handleTransportEvent(
    TransportEvent event,
    bool suppressed,
  ) async {
    if (_terminal || suppressed) {
      return;
    }

    switch (event.status) {
      case TransportStatus.connecting:
      case TransportStatus.connected:
        return;
      case TransportStatus.disconnected:
      case TransportStatus.closed:
        await _beginRecovery(
          event.error ??
              CallControllerException(
                'transport_${event.status.name}',
                'Call transport became ${event.status.name}',
              ),
          StackTrace.current,
        );
    }
  }

  Future<void> _handleChannelStreamError(
    Object error,
    StackTrace stackTrace,
    bool suppressed,
  ) async {
    if (_terminal || suppressed) {
      return;
    }
    await _beginRecovery(error, stackTrace);
  }

  Future<void> _handleSignalingEvent(SignalingEvent event) async {
    if (_terminal) {
      return;
    }

    // Any remote signal IS delivery evidence: the path is demonstrably
    // carrying frames right now. Recorded so soft send-timeouts can tell
    // "slow but advancing" apart from "silent" (see _beginRecovery).
    switch (event) {
      case RemoteDescriptionEvent():
      case RemoteIceCandidateEvent():
      case RestartRequestedEvent():
        _lastRemoteSignalAt = clock.now();
      default:
        break;
    }

    try {
      switch (event) {
        case RemoteDescriptionEvent():
          await _handleRemoteDescription(event.description);
        case RemoteIceCandidateEvent():
          if (!_ignoreOffer) {
            // A candidate the engine refuses is PARKED, not dropped and
            // not a call failure. The old drop rested on "a candidate
            // that matters is re-sent by the sender" — false by
            // construction: the signaling layer acks every envelope on
            // DELIVERY (before the app applies it), which cancels the
            // outbox retransmission, and the dedup kills any duplicate.
            // An application-level refusal is therefore a permanent loss
            // unless the receiver keeps the candidate itself (measured
            // 2026-08-09, loss60). Parked candidates re-apply after the
            // next successful setRemoteDescription; one that fails BOTH
            // times is genuinely stale (pre-restart ufrag) and dies
            // quietly — still never costing a recovery cycle.
            await _applyOrParkRemoteCandidate(event.candidate);
          }
        case RemoteHangupEvent():
          await _finishEnded(CallEndReason.remoteHangup);
        case RestartRequestedEvent():
          if (_signalingStarted) {
            await _negotiate(iceRestart: true);
          }
        case SignalingFailureEvent():
          await _beginRecovery(
            event.error,
            event.stackTrace ?? StackTrace.current,
          );
      }
    } on CallProtocolException catch (error, stackTrace) {
      await _fail(CallEndReason.protocolError, error, stackTrace);
    } catch (error, stackTrace) {
      await _beginRecovery(error, stackTrace);
    }
  }

  Future<void> _handleMediaEvent(MediaEvent event) async {
    if (_terminal) {
      return;
    }

    switch (event) {
      case LocalIceCandidateEvent():
        if (_signalingStarted) {
          try {
            await _bounded(
              signaling.send(SendIceCandidateCommand(event.candidate)),
              'send local ICE candidate',
            );
          } catch (error, stackTrace) {
            _bufferLocalCandidate(event.candidate);
            await _beginRecovery(error, stackTrace);
          }
        } else {
          _bufferLocalCandidate(event.candidate);
        }

      case MediaConnectionChangedEvent():
        switch (event.state) {
          case MediaConnectionState.connected:
            _everConnected = true;
            _cancelMediaDisconnectGrace();
            _completeRecovery();
            if (_state.phase != CallPhase.connected) {
              _emit(CallPhase.connected);
            }
          case MediaConnectionState.disconnected:
            // SQUALL, NOT DEATH (raised 2026-08-08, loss60 draws 2-3):
            // under heavy loss ICE reports `disconnected` on a burst of
            // missed checks and usually self-heals within seconds once
            // one lands; an instant restart trades a seconds-long squall
            // for a fresh connect lottery (measured: three restarts in
            // 21 s, then a connected call whose data channels never got
            // to open). Grace = connectionTimeout/4, floor 2 s cap 20 s;
            // `connected` cancels it; `failed`/`closed` stay immediate.
            if (_mediaDisconnectGraceTimer == null && !_terminal) {
              final graceMs = (connectionTimeout.inMilliseconds ~/ 4).clamp(
                2000,
                20000,
              );
              _mediaDisconnectGraceTimer = Timer(
                Duration(milliseconds: graceMs),
                () {
                  _mediaDisconnectGraceTimer = null;
                  _enqueueEvent(() async {
                    if (_terminal) {
                      return;
                    }
                    await _beginRecovery(
                      const CallControllerException(
                        'media_disconnected',
                        'Media connection stayed disconnected past its '
                            'squall grace window',
                      ),
                      StackTrace.current,
                    );
                  });
                },
              );
            }
          case MediaConnectionState.failed:
            _cancelMediaDisconnectGrace();
            await _beginRecovery(
              event.error ??
                  CallControllerException(
                    'media_${event.state.name}',
                    'Media connection became ${event.state.name}',
                  ),
              StackTrace.current,
            );
          case MediaConnectionState.closed:
            _cancelMediaDisconnectGrace();
            _mediaStarted = false;
            await _beginRecovery(
              event.error ??
                  const CallControllerException(
                    'media_closed',
                    'Media session closed unexpectedly',
                  ),
              StackTrace.current,
            );
          case MediaConnectionState.newConnection:
          case MediaConnectionState.connecting:
            return;
        }

      case MediaFailureEvent():
        await _beginRecovery(
          event.error,
          event.stackTrace ?? StackTrace.current,
        );
    }
  }

  /// Applies a remote candidate now, or parks it for the next remote
  /// description when the engine refuses it (see the handler comment —
  /// the sender can never re-send a refused candidate). Drop-oldest at
  /// [maxBufferedIceCandidates], mirroring the local buffer.
  Future<void> _applyOrParkRemoteCandidate(IceCandidate candidate) async {
    try {
      await _boundedEngine(
        media.addRemoteIceCandidate(candidate),
        'add remote ICE candidate',
      );
    } catch (_) {
      _pendingRemoteCandidates.add(candidate);
      if (_pendingRemoteCandidates.length > maxBufferedIceCandidates) {
        _pendingRemoteCandidates.removeAt(0);
      }
    }
  }

  /// Re-applies parked remote candidates; runs after every successful
  /// setRemoteDescription. A candidate that fails its re-apply belonged
  /// to a previous ICE generation and is dropped for good.
  Future<void> _drainPendingRemoteCandidates() async {
    if (_pendingRemoteCandidates.isEmpty) {
      return;
    }
    final parked = List<IceCandidate>.of(_pendingRemoteCandidates);
    _pendingRemoteCandidates.clear();
    for (final candidate in parked) {
      try {
        await _boundedEngine(
          media.addRemoteIceCandidate(candidate),
          'add remote ICE candidate',
        );
      } catch (_) {
        // Failed on arrival AND after the description it could have
        // belonged to: genuinely stale, dies quietly.
      }
    }
  }

  Future<void> _handleRemoteDescription(SessionDescription description) async {
    switch (description.type) {
      case SessionDescriptionType.offer:
        final collision =
            _makingOffer || media.signalingState != MediaSignalingState.stable;
        final polite = role == CallRole.receiver;

        _ignoreOffer = !polite && collision;
        if (_ignoreOffer) {
          return;
        }

        if (collision) {
          await _boundedEngine(media.rollback(), 'rollback local description');
        }

        await _boundedEngine(
          media.setRemoteDescription(description),
          'set remote offer',
        );
        await _drainPendingRemoteCandidates();
        final answer = await _boundedEngine(
          media.createAnswer(),
          'create answer',
        );
        if (answer.type != SessionDescriptionType.answer) {
          throw CallProtocolException(
            'Media adapter returned ${answer.type.name} from createAnswer',
          );
        }

        await _boundedEngine(
          media.setLocalDescription(answer),
          'set local answer',
        );
        await _bounded(
          signaling.send(SendDescriptionCommand(answer)),
          'send answer',
        );
        _ignoreOffer = false;

      case SessionDescriptionType.answer:
        if (media.signalingState != MediaSignalingState.haveLocalOffer) {
          return;
        }
        await _boundedEngine(
          media.setRemoteDescription(description),
          'set remote answer',
        );
        await _drainPendingRemoteCandidates();
        _ignoreOffer = false;
    }
  }

  Future<void> _negotiate({required bool iceRestart}) async {
    if (_terminal || !_signalingStarted) {
      return;
    }

    if (_makingOffer) {
      return;
    }

    _makingOffer = true;
    try {
      if (iceRestart && media.signalingState != MediaSignalingState.stable) {
        await _boundedEngine(media.rollback(), 'rollback before ICE restart');
      }

      final offer = await _boundedEngine(
        media.createOffer(iceRestart: iceRestart),
        iceRestart ? 'create ICE restart offer' : 'create offer',
      );
      if (offer.type != SessionDescriptionType.offer) {
        throw CallProtocolException(
          'Media adapter returned ${offer.type.name} from createOffer',
        );
      }

      await _boundedEngine(media.setLocalDescription(offer), 'set local offer');
      await _bounded(
        signaling.send(SendDescriptionCommand(offer)),
        'send offer',
      );
    } finally {
      _makingOffer = false;
    }
  }

  Future<void> _ensureMediaStarted() async {
    if (_mediaStarted) {
      return;
    }
    // start() contains getUserMedia — human latency (permission prompt),
    // not compute — so it gets its own bound; see [mediaStartTimeout].
    await _boundedBy(media.start(), 'start media session', mediaStartTimeout);
    _mediaStarted = true;
  }

  Future<void> _connectChannels() async {
    await _bounded(transport.connect(), 'connect transport');
    await _bounded(
      signaling.start(callId: callId, role: role),
      'start signaling',
    );
    _signalingStarted = true;
    await _flushLocalCandidates();
  }

  Future<void> _resetChannels() async {
    _suppressChannelEvents = true;
    try {
      if (_signalingStarted) {
        await _bestEffort(() => _bounded(signaling.stop(), 'stop signaling'));
      }
      _signalingStarted = false;
      await _bestEffort(
        () => _bounded(transport.disconnect(), 'disconnect transport'),
      );
    } finally {
      _suppressChannelEvents = false;
    }
  }

  /// INITIAL-CONNECT WATCHDOG — the recovery loop's missing first rung.
  ///
  /// The recovery loop already bounds every RE-negotiation with
  /// [connectionTimeout] and schedules the next attempt when media never
  /// arrives (`_performRecoveryAttempt`). The INITIAL negotiation had no
  /// such bound: nothing throws on the happy path, so nothing fired.
  /// Measured 2026-08-07 (T2 loss60, 60% per-direction loss): both peers
  /// sat in `negotiating` with error=null for the entire connect budget —
  /// the pcap showed 59 TURN Allocate packets and almost no ICE, because
  /// the Allocate responses kept being dropped and gathering quietly
  /// produced no relay candidate. Under a relay-only ICE policy an empty
  /// gathering is SILENT: no error, no state change, nothing to recover
  /// from — indistinguishable from slow, except by time.
  ///
  /// So time is the detector: if one modeled attempt cost passes without a
  /// connected call, the controller enters its NORMAL recovery loop, whose
  /// ICE restart re-runs gathering — a fresh TURN allocation with fresh
  /// luck — bounded by the reconnect policy exactly like every other
  /// recovery.
  void _cancelMediaDisconnectGrace() {
    _mediaDisconnectGraceTimer?.cancel();
    _mediaDisconnectGraceTimer = null;
  }

  void _armInitialConnectWatchdog() {
    _initialConnectTimer?.cancel();
    _initialAttemptStartedAt ??= clock.now();
    _initialConnectTimer = Timer(connectionTimeout, () {
      _initialConnectTimer = null;
      _enqueueEvent(() async {
        if (_terminal ||
            _recoveryActive ||
            _state.phase == CallPhase.connected ||
            _state.phase == CallPhase.degraded) {
          return;
        }
        // Progress-aware: when the far side delivered within the window,
        // the negotiation is advancing — extend patience (re-arm) instead
        // of restarting the very sequence that is landing. CAPPED at 2x
        // connectionTimeout of total attempt age (raised 2026-08-09,
        // loss60 clean-window: frames TRICKLING every <window kept the
        // patience alive for 220s while the handshake never completed —
        // mere arrival is not completion, and an uncapped extension
        // spends the whole connect budget on one doomed draw).
        final last = _lastRemoteSignalAt;
        final attemptAge = _initialAttemptStartedAt == null
            ? Duration.zero
            : clock.now().difference(_initialAttemptStartedAt!);
        if (last != null &&
            clock.now().difference(last) < connectionTimeout &&
            attemptAge < connectionTimeout * 2) {
          _armInitialConnectWatchdog();
          return;
        }
        _initialAttemptStartedAt = null;
        await _beginRecovery(
          CallControllerException(
            'initial_connection_timeout',
            'Negotiation did not produce a connected call within one '
                'modeled attempt cost (${connectionTimeout.inSeconds}s)',
          ),
          StackTrace.current,
        );
      });
    });
  }

  Future<void> _beginRecovery(Object cause, StackTrace stackTrace) async {
    if (_terminal || !_started) {
      return;
    }

    // ADAPTIVE, not one-path (measured 2026-08-07, T2 loss60): a
    // send-await timeout is SOFT under the at-least-once outbox — the
    // envelope keeps retransmitting after the await gives up. When the far
    // side has demonstrably delivered within one connectionTimeout, the
    // negotiation is slow-but-advancing, and cycling the socket here was
    // measured to reset exactly the progress it was waiting for (the run
    // reached offer-delivered/answer-in-flight five times and reset five
    // times). Silence keeps the hard cycle; progress extends patience —
    // bounded as ever by the reconnect policy's outer budget.
    // ONE JUDGE OF STAGNATION (raised 2026-08-08, loss60 with relay-tcp):
    // the recency clause above was the wrong ruler — under 60% loss the
    // NATURAL gap between healthy inbound signals exceeds one
    // connectionTimeout, so send-await timeouts kept winning the race
    // against the watchdog and cycled a socket whose outbox was still
    // retransmitting (measured: three ~150s cycles ate the 450s budget;
    // 'send local ICE candidate' timed out at 73s while the transport
    // was open). During the initial connect, EVERY send-await timeout is
    // soft: it re-arms the progress-aware watchdog and returns. The
    // watchdog alone declares stagnation — when it fires with no recent
    // remote delivery it begins recovery with its own non-Timeout cause,
    // so true silence still cycles exactly once per modeled attempt.
    final progressedRecently =
        !_everConnected &&
        !_recoveryActive &&
        cause is TimeoutException &&
        // Engine bounds are LOCAL compute deadlines — a wedged engine is
        // not slow signalling, and deferring it to the watchdog would
        // just delay a certain failure (the setLocalDescription-hung
        // test pins this).
        cause is! EngineTimeoutException &&
        (_state.phase == CallPhase.negotiating ||
            _state.phase == CallPhase.connecting);
    if (progressedRecently) {
      // Swallow — but grant NO fresh patience. The watchdog's existing
      // deadline stands; only REMOTE delivery (checked when it fires)
      // extends it. Re-arming here let periodic send-timeouts push the
      // deadline forever and the judge never ruled (measured 2026-08-08
      // loss60: initiator spent the whole 450s budget in negotiating).
      if (_initialConnectTimer == null) {
        _armInitialConnectWatchdog();
      }
      return;
    }

    _initialConnectTimer?.cancel();
    _initialConnectTimer = null;
    _cancelMediaDisconnectGrace();
    _lastRecoveryCause = cause;
    if (!_recoveryActive) {
      _recoveryActive = true;
      _recoveryAttempt = 0;
      _recoveryStartedAt = clock.now().toUtc();
    }

    if (_recoveryAttemptInFlight) {
      return;
    }

    if (_waitingForConnection) {
      _waitingForConnection = false;
      _recoveryTimer?.cancel();
      _recoveryTimer = null;
    } else if (_recoveryTimer != null) {
      return;
    }

    await _scheduleNextRecovery(cause, stackTrace);
  }

  Future<void> _scheduleNextRecovery(
    Object cause,
    StackTrace stackTrace,
  ) async {
    if (_terminal) {
      return;
    }

    final startedAt = _recoveryStartedAt ?? clock.now().toUtc();
    final nextAttempt = _recoveryAttempt + 1;
    late final ReconnectDecision decision;

    try {
      decision = reconnectPolicy.evaluate(
        ReconnectContext(
          attempt: nextAttempt,
          elapsed: clock.now().toUtc().difference(startedAt),
          cause: cause,
        ),
      );
    } catch (error, policyStackTrace) {
      await _fail(
        CallEndReason.reconnectExhausted,
        CallControllerException(
          'invalid_reconnect_policy',
          'Reconnect policy evaluation failed',
          cause: error,
        ),
        policyStackTrace,
      );
      return;
    }

    if (!decision.shouldRetry) {
      await _fail(
        CallEndReason.reconnectExhausted,
        CallControllerException(
          'reconnect_exhausted',
          decision.reason ?? 'Reconnect policy declined another attempt',
          cause: cause,
        ),
        stackTrace,
      );
      return;
    }

    final retryAt = clock.now().toUtc().add(decision.delay);
    _emit(
      CallPhase.reconnecting,
      reconnectAttempt: nextAttempt,
      nextRetryAt: retryAt,
      error: cause,
    );

    _recoveryTimer?.cancel();
    _recoveryTimer = Timer(decision.delay, () {
      _recoveryTimer = null;
      _enqueueEvent(() => _performRecoveryAttempt(nextAttempt));
    });
  }

  Future<void> _performRecoveryAttempt(int attempt) async {
    if (_terminal || !_recoveryActive || attempt != _recoveryAttempt + 1) {
      return;
    }

    _recoveryAttempt = attempt;
    _recoveryAttemptInFlight = true;
    _waitingForConnection = false;

    // ADAPTIVE ATTEMPT (measured 2026-08-07, T2 loss60): when the far side
    // delivered a signaling frame within the last connectionTimeout, the
    // in-flight negotiation is ADVANCING — offer and answer were measured
    // delivered with candidates still flushing when the old
    // unconditional reset threw the progress away, attempt after attempt.
    // A progressing attempt therefore keeps its channels and its
    // negotiation (the at-least-once outbox is still retransmitting the
    // pending frames) and only re-waits for media. A SILENT attempt keeps
    // the full reset + ICE-restart cycle — fresh sockets are how silence
    // is escaped. The policy's attempt/elapsed accounting runs either way,
    // so the outer budget still bounds everything.
    // Progress-aware patience applies to the 2nd-and-later attempts of
    // any recovery: the FIRST attempt always hard-cycles. Post-connected
    // that was always the rule (a proven path died — fresh ICE restart
    // is the correct medicine); for the initial connect the watchdog has
    // ALREADY granted this generation 2x connectionTimeout of chatter
    // patience before handing off, so letting attempt 1 re-enter the
    // progressing skip overturned the watchdog's own ruling (raised
    // 2026-08-09, loss60). Once a fresh cycle's negotiation is
    // demonstrably delivering frames, resetting it again burns the very
    // sequence being waited for (measured 2026-08-07) — so attempts 2+
    // keep the recency skip, but CAPPED at 2x connectionTimeout since
    // the last hard cycle: mere arrival is not completion, and an
    // uncapped extension spends the whole reconnect budget on one
    // doomed generation.
    final last = _lastRemoteSignalAt;
    final cycleBaseline = _recoveryHardCycleAt ?? _recoveryStartedAt;
    final patienceFresh =
        cycleBaseline == null ||
        clock.now().difference(cycleBaseline) < connectionTimeout * 2;
    // ONE GENERATION FOR THE INITIAL CONNECT (wiretap-proven 2026-08-09):
    // under heavy loss each signaling leg is a TCP retransmit ladder —
    // measured first-delivery latencies of 54 s, 111 s, 194 s, 269 s on a
    // LIVE socket — so any time-based reset window shorter than the whole
    // connect budget misjudges an in-flight leg as silence. Across four
    // instrumented draws every time-triggered reset destroyed a
    // negotiation whose frames later arrived (offer@111s vs reset@87s,
    // answer@269s vs reset@229s) and re-entered the dial lottery; not one
    // reset helped. Until the call has EVER connected, recovery attempts
    // therefore never tear the generation down on time alone — the
    // at-least-once outbox and hedge-promoting transport keep grinding
    // the SAME generation, late candidates park and re-apply, and the
    // reconnect policy's elapsed budget remains the only clock. Real
    // failures (signaling/engine/media events) still arrive here as
    // recovery causes and still reset. Post-connected recovery keeps the
    // proven shape: first attempt hard-cycles, later attempts extend on
    // recency, capped at 2x connectionTimeout since the last hard cycle.
    // Only TIME-DRIVEN causes get that one-generation patience: a real
    // failure (signaling channel death, engine error, media failure)
    // still hard-cycles immediately — patience cannot resurrect a dead
    // channel, only a reset can.
    final cause = _lastRecoveryCause;
    final timeDriven =
        cause is CallControllerException &&
        (cause.code == 'initial_connection_timeout' ||
            cause.code == 'reconnect_connection_timeout');
    final progressing =
        (!_everConnected && timeDriven) ||
        (attempt > 1 &&
            patienceFresh &&
            last != null &&
            clock.now().difference(last) < connectionTimeout);

    try {
      if (!progressing) {
        _recoveryHardCycleAt = clock.now();
        await _resetChannels();
        await _ensureMediaStarted();
        await _connectChannels();

        if (role == CallRole.initiator) {
          await _negotiate(iceRestart: true);
        } else {
          await _bounded(
            signaling.send(const SendRestartRequestCommand()),
            'request ICE restart',
          );
          // SINGLE-OWNER GENERATIONS during the initial connect (raised
          // 2026-08-09, loss60): two independent judges resetting one
          // shared negotiation trampled each other's draws — the
          // receiver's own iceRestart negotiate raced the initiator's
          // fresh offer and glared, attempt after attempt. Before the
          // call has EVER connected the initiator owns every generation:
          // the receiver refreshes its channels, asks for a restart, and
          // ANSWERS what arrives. Post-connected recoveries keep the
          // receiver-side negotiate (its rollback path is proven there).
          if (_everConnected) {
            await _negotiate(iceRestart: true);
          }
        }
      }

      _recoveryAttemptInFlight = false;

      if (media.connectionState == MediaConnectionState.connected) {
        _completeRecovery();
        if (_state.phase != CallPhase.connected) {
          _emit(CallPhase.connected);
        }
        return;
      }

      _waitingForConnection = true;
      _armRecoveryWait();
    } catch (error, stackTrace) {
      _recoveryAttemptInFlight = false;
      _waitingForConnection = false;
      _lastRecoveryCause = error;
      await _scheduleNextRecovery(error, stackTrace);
    }
  }

  /// The recovery attempt's wait-for-media timer, PROGRESS-AWARE (the
  /// user's own diagnosis, 2026-08-08): after a severe drop the restart's
  /// renegotiation frames crawl back over the same impaired link, and a
  /// blind connectionTimeout fired while re-ACKs were demonstrably in
  /// flight — chopping every restart attempt at a fraction of its own
  /// modeled attempt cost. On fire: remote signaling within the window →
  /// re-arm and keep waiting (the negotiation is landing); silence → the
  /// next recovery attempt, exactly as before. The reconnect policy's
  /// elapsed budget bounds the whole loop either way.
  void _armRecoveryWait() {
    _recoveryTimer = Timer(connectionTimeout, () {
      _recoveryTimer = null;
      _enqueueEvent(() async {
        if (_terminal || !_recoveryActive || !_waitingForConnection) {
          return;
        }
        final last = _lastRemoteSignalAt;
        // Same 2x cap as the attempt's progressing skip: without it this
        // re-arm looped on chatter forever, bypassing the reconnect
        // policy's attempt/elapsed accounting entirely (2026-08-09).
        final cycleBaseline = _recoveryHardCycleAt ?? _recoveryStartedAt;
        final patienceFresh =
            cycleBaseline == null ||
            clock.now().difference(cycleBaseline) < connectionTimeout * 2;
        if (patienceFresh &&
            last != null &&
            clock.now().difference(last) < connectionTimeout) {
          _armRecoveryWait();
          return;
        }
        _waitingForConnection = false;
        final cause = CallControllerException(
          'reconnect_connection_timeout',
          'Media did not reconnect within the connection timeout',
          cause: _lastRecoveryCause,
        );
        _lastRecoveryCause = cause;
        await _scheduleNextRecovery(cause, StackTrace.current);
      });
    });
  }

  void _completeRecovery() {
    _initialConnectTimer?.cancel();
    _initialConnectTimer = null;
    _recoveryTimer?.cancel();
    _recoveryTimer = null;
    _recoveryHardCycleAt = null;
    _recoveryActive = false;
    _recoveryAttemptInFlight = false;
    _waitingForConnection = false;
    _recoveryAttempt = 0;
    _recoveryStartedAt = null;
    _lastRecoveryCause = null;
  }

  void _bufferLocalCandidate(IceCandidate candidate) {
    if (_pendingLocalCandidates.length >= maxBufferedIceCandidates) {
      _pendingLocalCandidates.removeAt(0);
    }
    _pendingLocalCandidates.add(candidate);
  }

  Future<void> _flushLocalCandidates() async {
    while (_signalingStarted &&
        !_terminal &&
        _pendingLocalCandidates.isNotEmpty) {
      final candidate = _pendingLocalCandidates.first;
      await _bounded(
        signaling.send(SendIceCandidateCommand(candidate)),
        'flush local ICE candidate',
      );
      _pendingLocalCandidates.removeAt(0);
    }
  }

  Future<void> _finishEnded(CallEndReason reason) async {
    if (_terminal) {
      return;
    }

    _terminal = true;
    _completeRecovery();
    await _teardown();
    _emit(CallPhase.ended, endReason: reason);
    _completeDone();
  }

  Future<void> _fail(
    CallEndReason reason,
    Object error,
    StackTrace stackTrace,
  ) async {
    if (_terminal) {
      return;
    }

    _terminal = true;
    _completeRecovery();
    await _teardown();
    _emit(CallPhase.failed, endReason: reason, error: error);
    _completeDone();
  }

  Future<void> _teardown() async {
    _suppressChannelEvents = true;
    try {
      if (_signalingStarted) {
        await _bestEffort(() => _bounded(signaling.stop(), 'stop signaling'));
      }
      _signalingStarted = false;

      await _bestEffort(
        () => _bounded(transport.disconnect(), 'disconnect transport'),
      );

      if (_mediaStarted) {
        await _bestEffort(
          () => _boundedEngine(media.stop(), 'stop media session'),
        );
      }
      _mediaStarted = false;
      _pendingLocalCandidates.clear();
    } finally {
      _cancelSubscriptions();
      _suppressChannelEvents = false;
    }
  }

  void _cancelSubscriptions() {
    if (_subscriptions.isEmpty) {
      return;
    }

    final subscriptions = List<StreamSubscription<Object?>>.of(_subscriptions);
    _subscriptions.clear();

    // NOT awaited, deliberately. StreamSubscription.cancel() on a stream
    // with no onCancel work returns the SDK's shared, ROOT-zone-completed
    // `_nullFuture`; awaiting it schedules the continuation on the real
    // event loop, outside any zone the caller controls. Measured
    // 2026-08-07 under fake_async: `_teardown` parked here until after the
    // test body finished, so the terminal `failed` state was emitted where
    // no test could observe it. Removing the listener is synchronous for
    // every source this controller subscribes to (sync broadcast
    // controllers); the returned future is a completion formality, and a
    // cancel that DID have async work owes nothing to teardown ordering —
    // late events are already guarded by `_terminal` checks and the
    // `_suppressChannelEvents` flag.
    for (final subscription in subscriptions) {
      try {
        unawaited(subscription.cancel());
      } catch (_) {
        // A throwing cancel must not abort the teardown of the rest.
      }
    }
  }

  void _emit(
    CallPhase phase, {
    int reconnectAttempt = 0,
    DateTime? nextRetryAt,
    CallEndReason? endReason,
    DegradedMode? degradedMode,
    Object? error,
  }) {
    if (!_isAllowedTransition(_state.phase, phase)) {
      throw StateError(
        'Invalid call state transition: ${_state.phase.name} -> ${phase.name}',
      );
    }

    final next = CallState(
      phase: phase,
      sequence: ++_sequence,
      changedAt: clock.now().toUtc(),
      reconnectAttempt: reconnectAttempt,
      nextRetryAt: nextRetryAt,
      endReason: endReason,
      degradedMode: degradedMode,
      error: error,
    );
    _state = next;

    if (!_stateController.isClosed) {
      _stateController.add(next);
    }
  }

  void _completeDone() {
    if (!_doneCompleter.isCompleted) {
      _doneCompleter.complete(_state);
    }
  }

  Future<T> _bounded<T>(Future<T> future, String operation) {
    return _boundedBy(future, operation, operationTimeout);
  }

  /// [_bounded] for local media-engine calls: same failure shape, but the
  /// network-independent [engineOperationTimeout] applies.
  Future<T> _boundedEngine<T>(Future<T> future, String operation) {
    return _boundedBy(future, operation, engineOperationTimeout, engine: true);
  }

  Future<T> _boundedBy<T>(
    Future<T> future,
    String operation,
    Duration limit, {
    bool engine = false,
  }) {
    return future.timeout(
      limit,
      onTimeout: () {
        if (engine) {
          throw EngineTimeoutException(
            'Timed out while attempting to $operation',
            limit,
          );
        }
        throw TimeoutException(
          'Timed out while attempting to $operation',
          limit,
        );
      },
    );
  }

  Future<void> _bestEffort(Future<void> Function() action) async {
    try {
      await action();
    } catch (_) {
      return;
    }
  }

  Future<T> _enqueue<T>(Future<T> Function() task) {
    final completer = Completer<T>();
    _serialTail = _serialTail.then((_) async {
      try {
        completer.complete(await task());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  void _enqueueEvent(Future<void> Function() task) {
    unawaited(
      _enqueue<void>(() async {
        if (_disposed) {
          return;
        }
        await task();
      }).catchError((Object _, StackTrace __) {}),
    );
  }

  void _ensureNotDisposed() {
    if (_disposed) {
      throw StateError('CallController has been disposed');
    }
  }

  static bool _isAllowedTransition(CallPhase from, CallPhase to) {
    if (from == to) {
      return true;
    }

    return switch (from) {
      CallPhase.idle =>
        to == CallPhase.connecting ||
            to == CallPhase.ending ||
            to == CallPhase.ended ||
            to == CallPhase.failed,
      CallPhase.connecting =>
        to == CallPhase.negotiating ||
            to == CallPhase.reconnecting ||
            to == CallPhase.ending ||
            to == CallPhase.failed,
      CallPhase.negotiating =>
        to == CallPhase.connected ||
            to == CallPhase.reconnecting ||
            to == CallPhase.ending ||
            to == CallPhase.failed,
      CallPhase.connected =>
        to == CallPhase.degraded ||
            to == CallPhase.reconnecting ||
            to == CallPhase.ending ||
            to == CallPhase.ended ||
            to == CallPhase.failed,
      CallPhase.degraded =>
        to == CallPhase.connected ||
            to == CallPhase.reconnecting ||
            to == CallPhase.ending ||
            to == CallPhase.ended ||
            to == CallPhase.failed,
      CallPhase.reconnecting =>
        to == CallPhase.connected ||
            to == CallPhase.ending ||
            to == CallPhase.ended ||
            to == CallPhase.failed,
      CallPhase.ending => to == CallPhase.ended || to == CallPhase.failed,
      CallPhase.ended => false,
      CallPhase.failed => false,
    };
  }

  static String _validateCallId(String value) {
    if (value.isEmpty || value.length > 128) {
      throw ArgumentError.value(value, 'callId');
    }

    final valid = RegExp(r'^[A-Za-z0-9._~-]+$');
    if (!valid.hasMatch(value)) {
      throw ArgumentError.value(
        value,
        'callId',
        'callId contains unsupported characters',
      );
    }
    return value;
  }
}

/// Local media-engine deadline exceeded (network-independent compute
/// bound). Distinct from [TimeoutException] so the initial-connect
/// soft-guard can defer network sends to the watchdog while a wedged
/// engine still fails fast.
final class EngineTimeoutException extends TimeoutException {
  EngineTimeoutException(super.message, super.duration);
}
