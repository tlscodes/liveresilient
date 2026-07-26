/// A direct device-to-device transport lane (Wi-Fi Direct / BLE) exposed to
/// the fabric as a standard [TransportChannel].
///
/// When the network is unreachable, two nearby devices can still exchange
/// traffic over the local radio. The radio itself binds through an injected
/// [LocalLinkBinding]; this class owns the transport contract, consent
/// gating, and health scoring so the fabric treats it like any other lane
/// and switches to it automatically. The wire format is the same standard
/// framing used on every other lane, between two consenting devices.
library;

import 'package:adaptive_transport/adaptive_transport.dart';
import 'package:device_link/device_link.dart' show DeviceLinkConsent;

/// Native P2P radio surface — bound with one closure each over the chosen
/// plugin (e.g. flutter_p2p_connection, flutter_blue_plus) in main.dart.
class LocalLinkBinding {
  const LocalLinkBinding({
    required this.discoverAndConnect,
    required this.sendBytes,
    required this.peerCount,
  });

  /// Establishes/refreshes a link to a nearby peer; true when at least one
  /// peer is reachable.
  final Future<bool> Function() discoverAndConnect;

  /// Sends one frame to the connected peer(s); true on acknowledged
  /// delivery.
  final Future<bool> Function(List<int> bytes) sendBytes;

  /// Number of peers currently linked (drives health).
  final int Function() peerCount;
}

/// Consent-gated local link channel.
class LocalLinkLane implements TransportChannel {
  LocalLinkLane({required this._binding, required this._consent});

  final LocalLinkBinding _binding;
  final DeviceLinkConsent _consent;

  @override
  String get name => 'local-link';

  @override
  final ChannelHealth health = ChannelHealth(
    // Local radio: very low latency, but modest reliability prior until
    // observed — a peer can walk out of range at any moment.
    reliabilityPrior: 0.7,
    bandwidth: 0.6,
    rttMs: 30,
  );

  @override
  Future<bool> probe() async {
    if (!_consent.granted) return false;
    final ok = await _binding.discoverAndConnect();
    health.pathDegraded = !ok || _binding.peerCount() == 0;
    return ok;
  }

  @override
  Future<SendResult> send(List<int> payload) async {
    // The link lane is a voluntary, owner-opted-in relay: no consent,
    // nothing leaves the device.
    if (!_consent.granted) {
      return const SendResult(SendStatus.unavailable);
    }
    if (_binding.peerCount() == 0) {
      final connected = await _binding.discoverAndConnect();
      if (!connected) return const SendResult(SendStatus.transient);
    }
    try {
      final ok = await _binding.sendBytes(payload);
      return ok
          ? const SendResult(SendStatus.ok, rttMs: 30)
          : const SendResult(SendStatus.transient);
    } catch (error) {
      return SendResult(SendStatus.unavailable, error: error);
    }
  }

  @override
  Future<void> dispose() async {}
}
