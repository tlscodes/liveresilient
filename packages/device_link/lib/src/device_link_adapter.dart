/// Local peer transport adapter.
///
/// Exposes a nearby-device link (local network / peer-to-peer Wi-Fi,
/// abstracted behind [LocalLinkPort]) as a [TransportChannel] so the
/// `PathSelector` can use it as a *last-resort* path when infrastructure
/// connectivity is degraded.
///
/// Hard policy, enforced at runtime in this class (not by convention):
/// - **consent-gated**: the adapter refuses to activate until
///   [DeviceLinkConsent.granted] is true — the user must have explicitly
///   enabled nearby connectivity in settings;
/// - **degraded-mode only**: sends are rejected while
///   [degradedModeActive] is false, so the local link never carries
///   traffic while normal paths work;
/// - **forwarding off by default**: this adapter delivers frames only
///   between directly-connected consenting peers. Multi-hop relay exists
///   solely in `MeshMessageProcessor` (same package) and stays disabled
///   unless the user opts in there as well;
/// - every frame is wrapped in an [AuthenticatedEnvelope]; unauthenticated
///   or replayed frames are dropped before reaching the application.
///
/// Designed from the v2 blueprint role, replacing the v1 `mesh_channel`
/// (which auto-joined peers and forwarded without authentication).
library;

import 'dart:async';

import 'package:adaptive_transport/adaptive_transport.dart';
import 'package:clock/clock.dart' hide Clock;

import 'authenticated_envelope.dart';

/// Live user-consent state, owned by the app's settings layer.
abstract interface class DeviceLinkConsent {
  /// True only while the user's explicit nearby-connectivity opt-in is
  /// active. Must reflect revocation immediately.
  bool get granted;
}

/// Platform port over the actual nearby link (e.g. local-network sockets or
/// a peer-to-peer Wi-Fi session). Discovery, pairing UX, and permission
/// prompts live in the app layer.
abstract interface class LocalLinkPort {
  /// Whether a peer is currently reachable.
  Future<bool> isPeerReachable();

  /// Sends raw bytes to the connected peer; returns the measured round-trip
  /// time when the link-level acknowledgement arrives.
  Future<int> sendBytes(List<int> bytes);

  /// Incoming raw frames from the peer.
  Stream<List<int>> get incomingFrames;

  Future<void> close();
}

class DeviceLinkAdapter implements TransportChannel {
  final LocalLinkPort _link;
  final DeviceLinkConsent _consent;
  final EnvelopeSigner _signer;
  final EnvelopeValidator _validator;
  final int Function() _nowMs;

  final _inboundController =
      StreamController<AuthenticatedEnvelope>.broadcast();
  StreamSubscription<List<int>>? _frameSubscription;

  bool _degradedModeActive = false;
  bool _disposed = false;

  @override
  final ChannelHealth health;

  DeviceLinkAdapter({
    required LocalLinkPort link,
    required DeviceLinkConsent consent,
    required EnvelopeSigner signer,
    required EnvelopeValidator validator,
    int Function()? nowMs,
  }) : _link = link,
       _consent = consent,
       _signer = signer,
       _validator = validator,
       _nowMs = nowMs ?? (() => clock.now().millisecondsSinceEpoch),
       health = ChannelHealth(
         // Local links are short-range and lossy: modest prior, decent
         // bandwidth, low starting RTT.
         reliabilityPrior: 0.6,
         bandwidth: 0.5,
         rttMs: 40,
         jitterMs: 15,
       ) {
    _frameSubscription = _link.incomingFrames.listen(
      _onFrame,
      onError: (Object _) {},
    );
  }

  @override
  String get name => 'local-peer';

  /// Authenticated inbound envelopes from the directly connected peer.
  Stream<AuthenticatedEnvelope> get inbound => _inboundController.stream;

  /// The router/app flips this when the [NetworkConditionProfile] reaches
  /// `degraded` or `isolated`, and back off on recovery.
  bool get degradedModeActive => _degradedModeActive;

  set degradedModeActive(bool active) {
    _degradedModeActive = active;
  }

  /// Whether policy currently allows this path to carry traffic.
  bool get activated => !_disposed && _consent.granted && _degradedModeActive;

  @override
  Future<bool> probe() async {
    if (!activated) return false;
    try {
      return await _link.isPeerReachable();
    } catch (_) {
      return false;
    }
  }

  @override
  Future<SendResult> send(List<int> payload) async {
    if (_disposed) {
      return const SendResult(SendStatus.unavailable);
    }
    if (!_consent.granted) {
      return SendResult(
        SendStatus.unavailable,
        error: StateError('Nearby connectivity has not been enabled.'),
      );
    }
    if (!_degradedModeActive) {
      return SendResult(
        SendStatus.unavailable,
        error: StateError(
          'Local peer path is reserved for degraded-mode operation.',
        ),
      );
    }

    try {
      final envelope = await AuthenticatedEnvelope.create(
        signer: _signer,
        payload: payload,
        nowMs: _nowMs(),
      );
      final rttMs = await _link.sendBytes(envelope.toBytes());
      return SendResult(SendStatus.ok, rttMs: rttMs);
    } on FormatException catch (e) {
      // Payload too large for the local link: not retryable on this path.
      return SendResult(SendStatus.unavailable, error: e);
    } on Exception catch (e) {
      // Operational failures from the link (I/O, timeout, etc.) are
      // retryable on another path — surfaced as transient, never thrown.
      // Narrowed from a bare `catch` (2026-07-18): a programming Error
      // (assertion, null-check, out-of-range) must propagate and crash
      // loudly instead of masquerading as a retryable transient send
      // failure. Verified against the test suite first: the only test
      // exercising this path (`send reports transient when the link
      // itself throws`) was updated to throw an `Exception`, matching what
      // a real link failure actually is — not a `StateError` (Dart's
      // convention for programming bugs).
      return SendResult(SendStatus.transient, error: e);
    }
  }

  Future<void> _onFrame(List<int> bytes) async {
    if (!activated || _inboundController.isClosed) return;

    final AuthenticatedEnvelope envelope;
    try {
      envelope = AuthenticatedEnvelope.fromBytes(bytes);
    } on FormatException {
      return; // Malformed frames are dropped silently.
    }

    final validation = await _validator.validate(envelope, nowMs: _nowMs());
    if (validation != EnvelopeValidation.valid) {
      return; // Unauthenticated / replayed / stale frames never surface.
    }

    _inboundController.add(envelope);
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _frameSubscription?.cancel();
    await _inboundController.close();
    await _link.close();
  }
}
