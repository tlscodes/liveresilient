/// Device-side binding seam: turns real platform plugins into the injected
/// closures the intelligence circuit expects, without pulling those plugins
/// into the CI gate.
///
/// Every factory here returns `null` (or a safe default) when no real
/// platform radio is wired, so the standalone demo and the test gate
/// build unchanged. On a real device build, replace the `null` returns with
/// the plugin call sites documented inline — one closure each — and the
/// fabric picks up the new lane automatically.
library;

import 'dart:io';

import 'package:adaptive_transport/adaptive_transport.dart';
import 'package:device_link/device_link.dart' show DeviceLinkConsent;

import 'local_link_lane.dart';

/// Owner opt-in for the voluntary local relay. Defaults to not granted:
/// the link lane stays dark until the user explicitly turns nearby-device
/// relaying on in settings, at which point this flips to `true`.
class LinkRelayConsent implements DeviceLinkConsent {
  bool _granted = false;
  @override
  bool get granted => _granted;

  void setGranted(bool value) => _granted = value;
}

/// Builds the local peer-to-peer lane if the platform exposes a link radio.
///
/// Returns `null` in the demo / test build (no plugin). On a real device,
/// bind a Wi-Fi Direct / BLE plugin (e.g. flutter_p2p_connection,
/// flutter_blue_plus) here by filling the three closures:
///
///   final binding = LocalLinkBinding(
///     discoverAndConnect: () => plugin.discover().then((_) => plugin.connectNearest()),
///     sendBytes: (bytes) => plugin.send(bytes),
///     peerCount: () => plugin.connectedPeers.length,
///   );
///   return buildLocalLinkLane(binding: binding, consent: consent);
TransportChannel? buildLocalLinkLane({
  LocalLinkBinding? binding,
  DeviceLinkConsent? consent,
}) {
  // No platform radio wired in the demo/gate build → no lane.
  if (binding == null) return null;
  return LocalLinkLane(
    binding: binding,
    consent: consent ?? LinkRelayConsent(),
  );
}

/// Where the intelligence brains persist their JSON files.
///
/// On iOS/Android the app sandbox exposes its own home; `Documents` under
/// it is the OS-backed persistent store (survives relaunches and, on iOS,
/// is not purgeable the way tmp is) — reachable from pure Dart via
/// `Platform.environment['HOME']`, zero plugin dependencies, so the gate
/// build stays plugin-free (the brief's CI-safety rule). Everywhere else
/// (tests, desktop dev) returns `null` and `bootIntelligence` keeps its
/// system-temp default.
Directory Function()? buildStorageDirectory() {
  if (!Platform.isIOS && !Platform.isAndroid) return null;
  final home = Platform.environment['HOME'];
  if (home == null || home.isEmpty) return null;
  final docs = Directory('$home/Documents/voice_call_kit_intelligence');
  return () => docs..createSync(recursive: true);
}
