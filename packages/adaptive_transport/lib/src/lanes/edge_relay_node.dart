/// The relay-side node: admission control in front, origin forwarding
/// behind.
///
/// One accepted connection takes exactly one of two paths, and the node
/// decides which from the first TLS record alone:
///
/// * **Authenticated** — the session is forwarded to the origin over an
///   internal encrypted channel. The client never learns the origin
///   address; it addressed the edge node and the edge node addressed the
///   origin.
/// * **Anything else** — the connection is spliced verbatim to the
///   fallback host by [RealityGate]. The node originates no bytes.
///
/// The security of the first path rests on a property that is easy to lose
/// and is therefore asserted here: the origin uplink is opened *by the
/// node*, from a connector the node holds, and no byte from the client
/// influences its address. A client-supplied hostname reaching
/// [OriginUplinkConnector] would turn this node into an open proxy — which
/// is why the connector takes no address argument at all.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:clock/clock.dart';

import '../probe_defense/reality_pass_through.dart';

/// Opens the internal channel to the origin.
///
/// Takes no address: the destination is fixed by the relay's own
/// configuration, never by anything the peer sent. Implementations are
/// expected to be encrypted end-to-end (a TLS client socket, a WireGuard
/// tunnel, an authenticated session from the `security` package) — this
/// module does not manufacture that encryption, it requires it.
typedef OriginUplinkConnector = Future<DuplexByteStream> Function();

/// Counters for one relay node, for operational visibility.
class EdgeRelayNodeStats {
  int admitted = 0;
  int passedThrough = 0;
  int originUplinkFailures = 0;
  int bytesToOrigin = 0;
  int bytesToClient = 0;

  /// Share of connections that were probes rather than real clients. A
  /// value near 1.0 on a node with real users means the node's address has
  /// been discovered and is being scanned.
  double get passThroughRatio {
    final total = admitted + passedThrough;
    return total == 0 ? 0 : passedThrough / total;
  }

  @override
  String toString() => 'EdgeRelayNodeStats(admitted: $admitted, '
      'passedThrough: $passedThrough, '
      'uplinkFailures: $originUplinkFailures)';
}

/// Outcome of handling one connection at the node.
class EdgeRelayNodeOutcome {
  const EdgeRelayNodeOutcome({
    required this.admitted,
    required this.decisionLatency,
    this.reason,
    this.bytesToOrigin = 0,
    this.bytesToClient = 0,
    this.uplinkFailed = false,
  });

  final bool admitted;

  /// First byte to routing decision. The budget is under 2 ms; the node
  /// does a parse and one HMAC, nothing else, before deciding.
  final Duration decisionLatency;

  /// Set on the pass-through path only.
  final RealityRejectReason? reason;

  final int bytesToOrigin;
  final int bytesToClient;

  /// True when the client authenticated but the origin was unreachable.
  final bool uplinkFailed;
}

/// An edge relay node.
///
/// Owns no sockets of its own: [handle] is called with an accepted
/// connection, and the origin uplink comes from the injected connector.
/// That keeps the whole decision path testable without a network and lets
/// a deployment supply whatever transport its internal channel uses.
class EdgeRelayNodeServer {
  EdgeRelayNodeServer({
    required this.gate,
    required this.originUplink,
    this.uplinkTimeout = const Duration(seconds: 5),
  });

  /// Admission control and the pass-through path.
  final RealityGate gate;

  /// Opens the internal channel to the origin.
  final OriginUplinkConnector originUplink;

  final Duration uplinkTimeout;

  final EdgeRelayNodeStats stats = EdgeRelayNodeStats();

  /// Handles one accepted [client] connection to completion.
  ///
  /// On the authenticated path the consumed handshake bytes are replayed
  /// to the origin first, then the two streams are joined. On every other
  /// path [RealityGate] has already spliced the connection away and this
  /// method only records what happened.
  Future<EdgeRelayNodeOutcome> handle(DuplexByteStream client) async {
    DuplexByteStream? admittedClient;
    Uint8List? consumed;

    final gateOutcome = await gate.handle(
      client,
      onAdmitted: (stream, bytes, _) {
        admittedClient = stream;
        consumed = bytes;
      },
    );

    if (!gateOutcome.admitted) {
      stats.passedThrough++;
      stats.bytesToClient += gateOutcome.stats?.bytesToClient ?? 0;
      return EdgeRelayNodeOutcome(
        admitted: false,
        decisionLatency: gateOutcome.elapsed,
        reason: gateOutcome.decision.reason,
        bytesToClient: gateOutcome.stats?.bytesToClient ?? 0,
      );
    }

    stats.admitted++;
    return _forwardToOrigin(
      admittedClient!,
      consumed ?? Uint8List(0),
      gateOutcome.elapsed,
    );
  }

  Future<EdgeRelayNodeOutcome> _forwardToOrigin(
    DuplexByteStream client,
    Uint8List consumed,
    Duration decisionLatency,
  ) async {
    DuplexByteStream origin;
    try {
      origin = await originUplink().timeout(uplinkTimeout);
    } catch (_) {
      stats.originUplinkFailures++;
      // The client authenticated, so it is a real user and not a scanner —
      // but the node still says nothing. An error message here would be a
      // distinguishing response emitted by the edge address, and the
      // client's own failover will move it to another node in less time
      // than an error would have saved it.
      await _closeQuietly(client);
      return EdgeRelayNodeOutcome(
        admitted: true,
        decisionLatency: decisionLatency,
        uplinkFailed: true,
      );
    }

    var toOrigin = 0;
    var toClient = 0;
    if (consumed.isNotEmpty) {
      origin.add(consumed);
      toOrigin += consumed.length;
    }

    final done = Completer<void>();
    void finish() {
      if (!done.isCompleted) done.complete();
    }

    final clientSub = client.inbound.listen(
      (chunk) {
        origin.add(chunk);
        toOrigin += chunk.length;
      },
      onDone: finish,
      onError: (Object _) => finish(),
      cancelOnError: true,
    );
    final originSub = origin.inbound.listen(
      (chunk) {
        client.add(chunk);
        toClient += chunk.length;
      },
      onDone: finish,
      onError: (Object _) => finish(),
      cancelOnError: true,
    );

    await done.future;
    await clientSub.cancel();
    await originSub.cancel();
    await _closeQuietly(client);
    await _closeQuietly(origin);

    stats.bytesToOrigin += toOrigin;
    stats.bytesToClient += toClient;
    return EdgeRelayNodeOutcome(
      admitted: true,
      decisionLatency: decisionLatency,
      bytesToOrigin: toOrigin,
      bytesToClient: toClient,
    );
  }

  static Future<void> _closeQuietly(DuplexByteStream stream) async {
    try {
      await stream.close();
    } catch (_) {
      // Already gone.
    }
  }
}

/// Wraps a [DuplexByteStream] and records the time of first byte, so a
/// node can measure decision latency against its own budget rather than
/// against a stopwatch started at accept time.
class TimestampedDuplexStream implements DuplexByteStream {
  TimestampedDuplexStream(this._inner);

  final DuplexByteStream _inner;

  /// When the first inbound byte arrived, or null if none has.
  DateTime? firstByteAt;

  @override
  Stream<Uint8List> get inbound => _inner.inbound.map((chunk) {
        firstByteAt ??= clock.now();
        return chunk;
      });

  @override
  void add(Uint8List bytes) => _inner.add(bytes);

  @override
  Future<void> close() => _inner.close();
}
