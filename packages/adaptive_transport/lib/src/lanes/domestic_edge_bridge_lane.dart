/// A transport lane that reaches the call relay through a pool of
/// nearby ("domestic") edge endpoints, speaking the standard gRPC
/// length-prefixed message framing over an already-established HTTP/2 or
/// HTTP/3 stream.
///
/// Three properties define this lane:
///
/// 1. **Standard framing only.** Every message on the wire is the wire
///    format gRPC itself defines: one compression flag byte, a 4-byte
///    big-endian length, then that many payload bytes. The lane adds no
///    custom HTTP headers, no magic prefix, and no per-connection nonce —
///    nothing that would distinguish its streams from any other gRPC
///    traffic to the same edge.
/// 2. **Round-robin edge rotation.** Endpoints are tried in a rotating
///    order so no single edge carries a whole call and so a newly healthy
///    edge re-enters service without an explicit reset.
/// 3. **Sequence-preserving failover.** The message sequence counter
///    belongs to the *session*, not to the connection. Switching endpoints
///    mid-call continues the sequence, so the receiver reassembles across
///    a failover exactly as it would across a clean stream.
library;

import 'dart:async';
import 'dart:io' show gzip;
import 'dart:typed_data';

import '../probe_defense/traffic_shaper.dart';
import '../transport_channel.dart';

/// The gRPC length-prefixed message framing (one flag byte + uint32 BE
/// length + payload).
///
/// Pure and dependency-free so both ends and the tests share one
/// definition of the wire format.
class GrpcMessageFramer {
  const GrpcMessageFramer();

  /// Size of the fixed header: 1 compression flag + 4 length bytes.
  static const int headerLength = 5;

  /// Compression flag for an uncompressed message, per the gRPC wire
  /// format. This lane never sets the compressed flag: payloads arrive
  /// already coded by the media stage.
  static const int uncompressedFlag = 0x00;

  /// Compression flag for a message whose payload is compressed with the
  /// stream's negotiated encoding. This lane never *sets* it — payloads
  /// arrive already coded by the media stage — but a conforming gRPC peer
  /// may, so the read path handles it rather than mis-parsing the body.
  /// gzip is the only encoding accepted; any other flag value is rejected.
  static const int compressedFlag = 0x01;

  /// Largest message this lane will accept off the wire, matching gRPC's
  /// own default receive limit. A length header is peer-controlled and can
  /// declare up to 4 GiB, so without a ceiling a peer can make the reader
  /// buffer indefinitely for a frame that never completes.
  static const int maxMessageLength = 4 * 1024 * 1024;

  /// Frames [payload] as a single gRPC message.
  Uint8List encode(List<int> payload) {
    final frame = Uint8List(headerLength + payload.length);
    frame[0] = uncompressedFlag;
    ByteData.sublistView(frame).setUint32(1, payload.length);
    frame.setRange(headerLength, frame.length, payload);
    return frame;
  }

  /// Reverses [encode] for one complete frame.
  ///
  /// A payload flagged compressed is inflated with gzip before it is
  /// returned, so callers always see plaintext.
  ///
  /// Throws [FormatException] when the frame is truncated, declares a
  /// length that does not match the bytes present, carries a compression
  /// flag other than 0 or 1, or inflates to more than [maxMessageLength].
  Uint8List decode(Uint8List frame) {
    if (frame.length < headerLength) {
      throw const FormatException('gRPC frame shorter than its header');
    }
    final declared = ByteData.sublistView(frame).getUint32(1);
    if (frame.length - headerLength != declared) {
      throw FormatException(
        'gRPC length header says $declared bytes, frame carries '
        '${frame.length - headerLength}',
      );
    }
    return decodeBody(
      frame[0],
      Uint8List.sublistView(frame, headerLength),
    );
  }

  /// Applies [flag] to an already-delimited message [body].
  ///
  /// Shared by [decode] and [GrpcFrameReader] so both paths treat the
  /// compression flag identically.
  static Uint8List decodeBody(int flag, Uint8List body) {
    switch (flag) {
      case uncompressedFlag:
        return body;
      case compressedFlag:
        final inflated = Uint8List.fromList(gzip.decode(body));
        if (inflated.length > maxMessageLength) {
          throw FormatException(
            'gRPC message inflates to ${inflated.length} bytes, over the '
            '$maxMessageLength-byte receive limit',
          );
        }
        return inflated;
      default:
        throw FormatException(
          'unsupported gRPC compression flag 0x${flag.toRadixString(16)}',
        );
    }
  }
}

/// Splits a byte stream into whole gRPC messages, tolerating arbitrary
/// chunk boundaries (an HTTP/2 DATA frame can carry half a message, or
/// several).
class GrpcFrameReader {
  final BytesBuilder _buffer = BytesBuilder(copy: true);

  /// Feeds [chunk] and returns every complete message it completed, in
  /// order. Incomplete trailing bytes stay buffered for the next call.
  List<Uint8List> add(List<int> chunk) {
    _buffer.add(chunk);
    final out = <Uint8List>[];
    var bytes = _buffer.toBytes();
    var offset = 0;
    while (bytes.length - offset >= GrpcMessageFramer.headerLength) {
      final view = ByteData.sublistView(bytes, offset);
      final declared = view.getUint32(1);
      if (declared > GrpcMessageFramer.maxMessageLength) {
        throw FormatException(
          'gRPC length header says $declared bytes, over the '
          '${GrpcMessageFramer.maxMessageLength}-byte receive limit',
        );
      }
      final total = GrpcMessageFramer.headerLength + declared;
      if (bytes.length - offset < total) break;
      out.add(GrpcMessageFramer.decodeBody(
        bytes[offset],
        Uint8List.fromList(
          bytes.sublist(
            offset + GrpcMessageFramer.headerLength,
            offset + total,
          ),
        ),
      ));
      offset += total;
    }
    _buffer.clear();
    if (offset < bytes.length) _buffer.add(bytes.sublist(offset));
    return out;
  }

  /// Drops any partially-received message. Called on endpoint switch: the
  /// half-message that died with the old connection can never complete.
  void reset() => _buffer.clear();
}

/// One open stream to a single edge endpoint.
///
/// Kept abstract so the lane depends on behavior, not on a particular
/// HTTP/2 or HTTP/3 client: production wires a real gRPC stream, tests
/// wire an in-memory pair. No third-party package is required either way.
abstract class EdgeBridgeConnection {
  /// Bytes arriving from the edge, in wire order.
  Stream<Uint8List> get inbound;

  /// Writes framed bytes toward the edge.
  void add(Uint8List frame);

  /// Flushes and closes the stream.
  Future<void> close();
}

/// Opens a stream to [endpoint]. Throwing (or timing out) marks the
/// endpoint unhealthy for this attempt.
typedef EdgeBridgeConnector = Future<EdgeBridgeConnection> Function(
  Uri endpoint,
);

/// A transport lane over a rotating pool of edge endpoints.
class DomesticEdgeBridgeLane implements TransportChannel {
  DomesticEdgeBridgeLane({
    required List<Uri> endpoints,
    required EdgeBridgeConnector connector,
    this.connectTimeout = const Duration(seconds: 3),
    this.minHealthCheckInterval = const Duration(seconds: 5),
    this.maxHealthCheckInterval = const Duration(minutes: 2),
    GrpcMessageFramer framer = const GrpcMessageFramer(),
    this.shaper,
    this.jitter,
  })  : _endpoints = List<Uri>.unmodifiable(endpoints),
        _connector = connector,
        _framer = framer,
        health = ChannelHealth(reliabilityPrior: 0.85, bandwidth: 0.8) {
    if (endpoints.isEmpty) {
      throw ArgumentError.value(endpoints, 'endpoints', 'at least one needed');
    }
  }

  final List<Uri> _endpoints;
  final EdgeBridgeConnector _connector;
  final GrpcMessageFramer _framer;

  /// How long a single connect attempt may take before the endpoint counts
  /// as unreachable for this rotation.
  final Duration connectTimeout;

  /// Floor and ceiling of the adaptive health-check backoff. The interval
  /// starts at the floor, doubles on every consecutive failed check, and
  /// snaps back to the floor the moment a check succeeds.
  final Duration minHealthCheckInterval;
  final Duration maxHealthCheckInterval;

  /// Optional length shaping. When set, each payload is padded to a drawn
  /// target length *before* gRPC framing, so the length the edge sees is
  /// the shaped one. Null leaves lengths untouched.
  ///
  /// The receiver must strip the padding with [TrafficShaper.unshape]; the
  /// lane deliberately does not do it for them, because only the caller
  /// knows whether the peer was configured with the same policy.
  final TrafficShaper? shaper;

  /// Optional send pacing. When set, [send] waits the drawn jitter before
  /// writing — the cost is added latency, bounded by the policy.
  final AdaptiveJitter? jitter;

  @override
  final ChannelHealth health;

  @override
  String get name => 'domestic-edge-bridge';

  /// The endpoints this lane rotates through, in rotation order.
  List<Uri> get endpoints => _endpoints;

  final GrpcFrameReader _reader = GrpcFrameReader();
  final StreamController<Uint8List> _received =
      StreamController<Uint8List>.broadcast();

  /// Whole application messages recovered from the edge, across every
  /// endpoint switch — the stream does not break on failover.
  Stream<Uint8List> get received => _received.stream;

  EdgeBridgeConnection? _connection;
  StreamSubscription<Uint8List>? _sub;
  int _rotation = 0;
  int _sessionSequence = 0;
  int _consecutiveCheckFailures = 0;
  bool _disposed = false;

  /// Index of the endpoint currently in use, or null while disconnected.
  int? _activeIndex;

  /// The endpoint currently carrying traffic, or null while disconnected.
  Uri? get activeEndpoint =>
      _activeIndex == null ? null : _endpoints[_activeIndex!];

  /// Number of messages this session has framed. Survives every endpoint
  /// switch: failover never rewinds it.
  int get sessionSequence => _sessionSequence;

  /// Current adaptive health-check interval, doubling per consecutive
  /// failure between [minHealthCheckInterval] and [maxHealthCheckInterval].
  Duration get healthCheckInterval {
    var micros = minHealthCheckInterval.inMicroseconds;
    for (var i = 0; i < _consecutiveCheckFailures; i++) {
      micros *= 2;
      if (micros >= maxHealthCheckInterval.inMicroseconds) {
        return maxHealthCheckInterval;
      }
    }
    return Duration(microseconds: micros);
  }

  /// Connects to the next endpoint in the rotation that accepts a stream.
  ///
  /// Every endpoint is tried at most once per call, starting one past the
  /// last one used, so a failing edge is skipped rather than retried in a
  /// tight loop. Throws [StateError] when the whole pool refuses.
  Future<EdgeBridgeConnection> _ensureConnected() async {
    final existing = _connection;
    if (existing != null) return existing;

    Object? lastError;
    for (var attempt = 0; attempt < _endpoints.length; attempt++) {
      final index = (_rotation + attempt) % _endpoints.length;
      try {
        final connection =
            await _connector(_endpoints[index]).timeout(connectTimeout);
        // A fresh stream cannot complete a message buffered from the dead
        // one; the session sequence, by contrast, deliberately continues.
        _reader.reset();
        _sub = connection.inbound.listen(
          (chunk) {
            for (final message in _reader.add(chunk)) {
              if (!_received.isClosed) _received.add(message);
            }
          },
          onDone: _dropConnection,
          onError: (Object _) => _dropConnection(),
          cancelOnError: true,
        );
        _connection = connection;
        _activeIndex = index;
        // Next connect starts at the endpoint after this one.
        _rotation = (index + 1) % _endpoints.length;
        return connection;
      } catch (error) {
        lastError = error;
      }
    }
    _rotation = (_rotation + 1) % _endpoints.length;
    throw StateError('no edge endpoint accepted a stream (last: $lastError)');
  }

  void _dropConnection() {
    _sub?.cancel();
    _sub = null;
    _connection = null;
    _activeIndex = null;
    _reader.reset();
  }

  Future<void> _closeConnection() async {
    final connection = _connection;
    _dropConnection();
    if (connection != null) {
      try {
        await connection.close();
      } catch (_) {
        // Already broken: there is nothing left to release.
      }
    }
  }

  /// Opens a stream (rotating if needed) and reports whether the pool is
  /// reachable, feeding the adaptive health-check backoff.
  @override
  Future<bool> probe() async {
    if (_disposed) return false;
    try {
      await _ensureConnected();
      _consecutiveCheckFailures = 0;
      health.observe(const SendResult(SendStatus.ok));
      return true;
    } catch (error) {
      _consecutiveCheckFailures++;
      health.observe(SendResult(SendStatus.unavailable, error: error));
      return false;
    }
  }

  /// Frames [payload] as one gRPC message and writes it to the active
  /// edge, rotating to another endpoint if the active one is gone.
  ///
  /// The sequence number is assigned once per accepted payload and is not
  /// rewound by a failover: a retry on a different endpoint carries the
  /// same number, so the receiver sees one continuous session.
  @override
  Future<SendResult> send(List<int> payload) async {
    if (_disposed) {
      return const SendResult(SendStatus.unavailable);
    }
    final shaped = shaper?.shape(payload) ?? payload;
    final frame = _framer.encode(shaped);
    final started = DateTime.now();
    // Paced before the write, not after: delaying the write is what moves
    // the packet's arrival time, which is the observable being shaped.
    await jitter?.pace();

    // Two passes at most: the first may write into a stream the peer has
    // already closed without our onDone having run yet.
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final connection = await _ensureConnected();
        connection.add(frame);
        _sessionSequence++;
        _consecutiveCheckFailures = 0;
        final result = SendResult(
          SendStatus.ok,
          rttMs: DateTime.now().difference(started).inMilliseconds,
        );
        health.observe(result);
        return result;
      } catch (error) {
        await _closeConnection();
        if (attempt == 1) {
          _consecutiveCheckFailures++;
          final result = SendResult(SendStatus.unavailable, error: error);
          health.observe(result);
          return result;
        }
      }
    }
    // Unreachable: the loop returns on both the success and the final
    // failure path.
    throw StateError('unreachable');
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _closeConnection();
    await _received.close();
  }
}
