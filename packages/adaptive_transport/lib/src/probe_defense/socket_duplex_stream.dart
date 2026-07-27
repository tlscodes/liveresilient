/// `dart:io` adapters for the probe-defense seams.
///
/// Kept in its own file so [RealityGate], [PassThroughRelay] and the
/// fingerprinting code stay free of `dart:io` and remain testable — and
/// portable — without a socket in sight.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'reality_pass_through.dart';
import 'tcp_stack_profile.dart';

/// Wraps a connected [Socket] as a [DuplexByteStream].
///
/// Buffers are forwarded by reference: nothing on the pass-through path
/// copies, re-slices, or reframes the bytes it carries.
class SocketDuplexStream implements DuplexByteStream {
  SocketDuplexStream(this.socket);

  final Socket socket;

  @override
  Stream<Uint8List> get inbound => socket;

  @override
  void add(Uint8List bytes) => socket.add(bytes);

  @override
  Future<void> close() async {
    try {
      await socket.flush();
    } catch (_) {
      // The peer is gone; the destroy below is what matters.
    }
    socket.destroy();
  }
}

/// Wraps a connected [RawSocket] as a [DuplexByteStream].
///
/// Exists because socket options live on [RawSocket] only — a plain
/// [Socket] cannot carry a [TcpStackProfile]. Reads are drained on `read`
/// events and writes are queued until the socket reports it can take them,
/// which is the bookkeeping [Socket] would otherwise do.
class RawSocketDuplexStream implements DuplexByteStream {
  RawSocketDuplexStream(this.socket) {
    _events = socket.listen(
      _onEvent,
      onError: _inbound.addError,
      onDone: _inbound.close,
    );
    socket.writeEventsEnabled = false;
  }

  final RawSocket socket;
  final _inbound = StreamController<Uint8List>();
  final _pending = BytesBuilder(copy: true);
  late final StreamSubscription<RawSocketEvent> _events;
  var _closed = false;

  void _onEvent(RawSocketEvent event) {
    switch (event) {
      case RawSocketEvent.read:
        final chunk = socket.read();
        if (chunk != null && chunk.isNotEmpty) _inbound.add(chunk);
      case RawSocketEvent.write:
        _drain();
      case RawSocketEvent.readClosed:
      case RawSocketEvent.closed:
        if (!_inbound.isClosed) _inbound.close();
      default:
        break;
    }
  }

  void _drain() {
    if (_pending.isEmpty) {
      socket.writeEventsEnabled = false;
      return;
    }
    final bytes = _pending.takeBytes();
    final written = socket.write(bytes);
    if (written < bytes.length) {
      _pending.add(Uint8List.sublistView(bytes, written));
      socket.writeEventsEnabled = true;
    } else {
      socket.writeEventsEnabled = false;
    }
  }

  @override
  Stream<Uint8List> get inbound => _inbound.stream;

  @override
  void add(Uint8List bytes) {
    if (_closed) return;
    _pending.add(bytes);
    _drain();
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _events.cancel();
    // Not awaited: an unlistened controller's close future only completes
    // once someone listens, which would hang a caller that never read.
    if (!_inbound.isClosed) unawaited(_inbound.close());
    socket.close();
  }
}

/// Connects to the fallback host over plain TCP.
///
/// Plain TCP is correct here and not an oversight: the relay must not
/// terminate TLS on this path. The probe's own Client Hello is replayed
/// upstream verbatim, so the TLS session it completes is with the real
/// host, using that host's real certificate.
///
/// With a [profile], the connection is made on a [RawSocket] so the
/// profile's observables can actually be set, and [onProfileApplied]
/// receives the ones that took. Without one, the simpler [Socket] path is
/// used unchanged.
Future<DuplexByteStream> connectFallbackSocket(
  String host,
  int port, {
  TcpStackProfile? profile,
  TcpSocketTuner tuner = const DartIoTcpSocketTuner(),
  void Function(List<String> applied)? onProfileApplied,
}) async {
  if (profile == null) {
    final socket = await Socket.connect(host, port);
    socket.setOption(SocketOption.tcpNoDelay, true);
    return SocketDuplexStream(socket);
  }
  final raw = await RawSocket.connect(host, port);
  raw.setOption(SocketOption.tcpNoDelay, true);
  onProfileApplied?.call(await tuner.apply(raw, profile));
  return RawSocketDuplexStream(raw);
}

/// Applies a [TcpStackProfile] to an outgoing connection where the
/// platform permits it, and reports which observables were actually set.
///
/// Returns the applied list; the caller is expected to compare it against
/// [TcpStackProfile.unreachableObservables] and decide whether the gap is
/// acceptable for its threat model rather than assume it is.
Future<List<String>> connectWithStackProfile({
  required String host,
  required int port,
  required TcpStackProfile profile,
  TcpSocketTuner tuner = const DartIoTcpSocketTuner(),
  Duration timeout = const Duration(seconds: 10),
  void Function(RawSocket socket)? onConnected,
}) async {
  final socket = await RawSocket.connect(host, port, timeout: timeout);
  final applied = await tuner.apply(socket, profile);
  onConnected?.call(socket);
  return applied;
}
