import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../host_port.dart';
import '../transport_channel.dart';

/// Primary transport path: plain UDP datagrams sent to our own media
/// endpoint. Honest, unencapsulated `RawDatagramSocket` traffic — no
/// tunneling, no third-party protocol impersonation. Highest bandwidth and
/// reliability prior of the resilient chain, and typically the lowest RTT,
/// but the first to degrade under restrictive corporate NAT/firewalls that
/// block outbound UDP.
class PrimaryUdpLane implements TransportChannel {
  PrimaryUdpLane({
    required HostPort remote,
    Duration probeTimeout = const Duration(milliseconds: 400),
  })  : _remote = remote,
        _probeTimeout = probeTimeout,
        health = ChannelHealth(reliabilityPrior: 0.9, bandwidth: 1.0);

  final HostPort _remote;
  final Duration _probeTimeout;

  RawDatagramSocket? _socket;
  InternetAddress? _resolvedAddress;

  /// The socket's single listener. [RawDatagramSocket] exposes a
  /// single-subscription stream, so the subscription is created once with
  /// the socket and lives as long as it: cancelling it per-probe and
  /// re-listening leaves every later probe deaf (the second listen never
  /// delivers), which reads as a permanently unreachable remote.
  StreamSubscription<RawSocketEvent>? _subscription;

  /// Completed by the listener when a datagram arrives while a probe is in
  /// flight. Null whenever no probe is waiting.
  Completer<bool>? _pendingProbe;

  @override
  final ChannelHealth health;

  @override
  String get name => 'primary-udp';

  Future<RawDatagramSocket> _ensureSocket() async {
    final existing = _socket;
    if (existing != null) return existing;
    final socket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      0,
    );
    _socket = socket;
    _subscription = socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      final packet = socket.receive();
      if (packet == null) return;
      final pending = _pendingProbe;
      if (pending != null && !pending.isCompleted) {
        pending.complete(true);
      }
    });
    return socket;
  }

  Future<InternetAddress> _resolveRemote() async {
    final cached = _resolvedAddress;
    if (cached != null) return cached;
    final host = _remote.host;
    final direct = InternetAddress.tryParse(host);
    if (direct != null) {
      _resolvedAddress = direct;
      return direct;
    }
    final looked = await InternetAddress.lookup(host);
    if (looked.isEmpty) {
      throw SocketException('Unable to resolve host: $host');
    }
    _resolvedAddress = looked.first;
    return looked.first;
  }

  /// Sends a 1-byte ping datagram (`0x00`) and awaits any echo datagram
  /// back from the remote within [_probeTimeout]. Testable against a real
  /// loopback UDP echo server.
  @override
  Future<bool> probe() async {
    try {
      final socket = await _ensureSocket();
      final address = await _resolveRemote();
      final started = DateTime.now();

      final completer = Completer<bool>();
      _pendingProbe = completer;

      socket.send(Uint8List.fromList(const [0x00]), address, _remote.port);

      final ok = await completer.future.timeout(
        _probeTimeout,
        onTimeout: () => false,
      );
      _pendingProbe = null;

      final rtt = DateTime.now().difference(started).inMilliseconds;
      health.observe(
        SendResult(ok ? SendStatus.ok : SendStatus.unavailable, rttMs: rtt),
      );
      return ok;
    } catch (error) {
      health.observe(SendResult(SendStatus.unavailable, error: error));
      return false;
    }
  }

  @override
  Future<SendResult> send(List<int> payload) async {
    try {
      final socket = await _ensureSocket();
      final address = await _resolveRemote();
      final started = DateTime.now();
      final sent = socket.send(
        Uint8List.fromList(payload),
        address,
        _remote.port,
      );
      final rtt = DateTime.now().difference(started).inMilliseconds;
      if (sent <= 0) {
        final result = SendResult(SendStatus.transient, rttMs: rtt);
        health.observe(result);
        return result;
      }
      final result = SendResult(SendStatus.ok, rttMs: rtt);
      health.observe(result);
      return result;
    } catch (error) {
      final result = SendResult(SendStatus.unavailable, error: error);
      health.observe(result);
      return result;
    }
  }

  @override
  Future<void> dispose() async {
    await _subscription?.cancel();
    _subscription = null;
    _pendingProbe = null;
    _socket?.close();
    _socket = null;
  }
}
