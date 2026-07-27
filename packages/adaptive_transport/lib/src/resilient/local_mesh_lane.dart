import '../transport_channel.dart';

/// Deepest fallback path: hand the frame to a nearby peer that still has
/// active egress (e.g. a BLE/WiFi-Direct mesh neighbor also on the call and
/// reachable over the internet). The actual radio transport is
/// infrastructure-specific and out of scope here — this class is a thin,
/// fully mockable abstraction over a single injectable [peerSender]
/// callback, so tests can simulate the mesh without any real radio stack.
///
/// Lowest reliability prior and bandwidth of the chain: it depends on a
/// third party's willingness and ability to relay, so it is only ever
/// reached once every standards-based direct path has failed.
class LocalMeshLane implements TransportChannel {
  LocalMeshLane({
    required Future<SendResult> Function(List<int> payload) peerSender,
    Future<bool> Function()? peerProbe,
    String name = 'local-mesh',
  })  : _peerSender = peerSender,
        _peerProbe = peerProbe,
        _name = name,
        health = ChannelHealth(reliabilityPrior: 0.35, bandwidth: 0.1);

  final Future<SendResult> Function(List<int> payload) _peerSender;
  final Future<bool> Function()? _peerProbe;
  final String _name;

  @override
  final ChannelHealth health;

  @override
  String get name => _name;

  @override
  Future<bool> probe() async {
    final probeFn = _peerProbe;
    if (probeFn == null) {
      // No dedicated probe hook: assume reachable and let send() surface
      // real failures via health/EWMA.
      return true;
    }
    try {
      final ok = await probeFn();
      health.observe(SendResult(ok ? SendStatus.ok : SendStatus.unavailable));
      return ok;
    } catch (error) {
      health.observe(SendResult(SendStatus.unavailable, error: error));
      return false;
    }
  }

  @override
  Future<SendResult> send(List<int> payload) async {
    try {
      final result = await _peerSender(payload);
      health.observe(result);
      return result;
    } catch (error) {
      final result = SendResult(SendStatus.unavailable, error: error);
      health.observe(result);
      return result;
    }
  }

  @override
  Future<void> dispose() async {}
}
