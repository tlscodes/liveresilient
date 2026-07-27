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

/// Connects to the fallback host over plain TCP.
///
/// Plain TCP is correct here and not an oversight: the relay must not
/// terminate TLS on this path. The probe's own Client Hello is replayed
/// upstream verbatim, so the TLS session it completes is with the real
/// host, using that host's real certificate.
Future<DuplexByteStream> connectFallbackSocket(String host, int port) async {
  final socket = await Socket.connect(host, port);
  socket.setOption(SocketOption.tcpNoDelay, true);
  return SocketDuplexStream(socket);
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
