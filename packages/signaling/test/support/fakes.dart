/// Test doubles shared by the signaling package's test suites.
///
/// Every timer in the production code under test (`ReliableOutbox`,
/// `SignalingClient`) is a real `Timer`/`Timer.periodic`, and every "now"
/// read goes through the ambient `clock` from `package:clock`. Tests drive
/// both through `fake_async`, so these doubles never introduce their own
/// timers or wall-clock reads.
library;

import 'dart:async';

import 'package:clock/clock.dart';
import 'package:signaling/signaling.dart';

/// In-memory [SignalingSocket] double.
///
/// - Push a frame as if it arrived from the server with [pushInbound] /
///   [pushInboundEnvelope]; the client's frame listener is asynchronous and
///   is not awaited by `Stream.listen`, so tests must call
///   `async.flushMicrotasks()` (or `async.elapse(...)`) afterwards.
/// - [sentFrames] accumulates every frame handed to [sendFrame], decoded
///   into a [SignalEnvelope] for easy assertions.
/// - [failSend] forces [sendFrame] to throw, exercising the client's
///   send-error-absorption paths.
/// - [emitError] / [emitDone] simulate the socket dying, exercising the
///   client's `onError` / `onDone` reconnect wiring respectively.
class FakeSocket implements SignalingSocket {
  final _framesController = StreamController<List<int>>.broadcast();
  final List<SignalEnvelope> sentFrames = [];

  bool closed = false;
  bool failSend = false;

  @override
  Stream<List<int>> get frames => _framesController.stream;

  @override
  Future<void> sendFrame(List<int> frame) async {
    if (failSend) {
      throw StateError('FakeSocket: simulated send failure.');
    }
    sentFrames.add(SignalEnvelope.fromBytes(frame));
  }

  @override
  Future<void> close() async {
    closed = true;
  }

  /// Simulates a raw frame arriving from the server.
  void pushInbound(List<int> frame) {
    if (_framesController.isClosed) return;
    _framesController.add(frame);
  }

  /// Simulates a well-formed envelope arriving from the server.
  void pushInboundEnvelope(SignalEnvelope envelope) {
    pushInbound(envelope.toBytes());
  }

  /// Simulates the socket dying with a transport error.
  void emitError(Object error) {
    if (_framesController.isClosed) return;
    _framesController.addError(error);
  }

  /// Simulates the remote end closing the connection cleanly.
  void emitDone() {
    if (_framesController.isClosed) return;
    _framesController.close();
  }
}

/// Records every connector invocation and hands out queued fake sockets
/// (or failures) in FIFO order; falls back to [defaultFactory] once the
/// queue is drained.
class CountingConnector {
  final List<Uri> calls = [];
  final List<SignalingSocket Function()> _queue = [];
  final List<FakeSocket> issuedSockets = [];

  /// Used once the queue is empty. Defaults to a fresh [FakeSocket] per
  /// call; tests simulating a persistent outage override this to throw.
  SignalingSocket Function() defaultFactory = FakeSocket.new;

  int get callCount => calls.length;

  FakeSocket? get lastSocket =>
      issuedSockets.isEmpty ? null : issuedSockets.last;

  /// Queues a successful connect returning [socket] (or a fresh
  /// [FakeSocket] if omitted).
  void queueSocket([FakeSocket? socket]) {
    final s = socket ?? FakeSocket();
    _queue.add(() => s);
  }

  /// Queues a failing connect attempt.
  void queueFailure([Object Function()? error]) {
    _queue.add(() => throw (error?.call() ?? StateError('connect failed')));
  }

  Future<SignalingSocket> call(Uri uri) async {
    calls.add(uri);
    final factory = _queue.isNotEmpty ? _queue.removeAt(0) : defaultFactory;
    final socket = factory();
    if (socket is FakeSocket) issuedSockets.add(socket);
    return socket;
  }
}

/// Records every transmit call handed to a [ReliableOutbox] and lets a
/// test force the next attempt to throw (transmission errors must be
/// absorbed, not propagated).
class RecordingTransmitter {
  final List<SignalEnvelope> log = [];
  bool accept = true;

  /// One-shot: if set, the next call throws this error instead of
  /// transmitting, then clears itself so later attempts succeed normally.
  Object? throwOnce;

  List<String> get ids => log.map((e) => e.messageId).toList();

  Future<bool> call(SignalEnvelope envelope) async {
    log.add(envelope);
    final pending = throwOnce;
    if (pending != null) {
      throwOnce = null;
      throw pending;
    }
    return accept;
  }
}

/// In-memory [OutboxStore] double that also records call order for
/// assertions on persistence wiring (`restore`/`save`/`remove`).
class InMemoryOutboxStore implements OutboxStore {
  final Map<String, SignalEnvelope> _entries = {};
  final List<String> saveCalls = [];
  final List<String> removeCalls = [];

  @override
  Future<void> save(SignalEnvelope envelope) async {
    _entries[envelope.messageId] = envelope;
    saveCalls.add(envelope.messageId);
  }

  @override
  Future<void> remove(String messageId) async {
    _entries.remove(messageId);
    removeCalls.add(messageId);
  }

  @override
  Future<List<SignalEnvelope>> loadAll() async => _entries.values.toList();

  /// Seeds the store as if a previous process had persisted it, skipping
  /// [save] so `restore()` sees only this pre-existing data.
  void seed(SignalEnvelope envelope) {
    _entries[envelope.messageId] = envelope;
  }
}

/// Builds a valid [SignalEnvelope] with sensible defaults, overridable per
/// field. `createdAtMs` defaults to the ambient `clock.now()` so callers
/// inside `withClock(...)` get a value consistent with the fake timeline.
SignalEnvelope testEnvelope({
  String? messageId,
  int sequence = 1,
  String callId = 'call-1',
  String senderKeyId = 'key-1',
  SignalType type = SignalType.offer,
  int? createdAtMs,
  Map<String, Object?> payload = const {'sdp': 'v=0'},
}) {
  return SignalEnvelope(
    messageId: messageId ?? generateSignalMessageId(),
    sequence: sequence,
    callId: callId,
    senderKeyId: senderKeyId,
    type: type,
    createdAtMs: createdAtMs ?? clock.now().millisecondsSinceEpoch,
    payload: payload,
  );
}
