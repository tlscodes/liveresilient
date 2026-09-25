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

/// This device's own DNS resolver, read from the platform's own system
/// API — never discovered, never scanned for. `TxtQueryResolvers.
/// systemResolvers` only reads `/etc/resolv.conf`, which the iOS sandbox
/// hides entirely and Android never publishes there either, so on a
/// phone the door's own "the network's own resolver races first"
/// promise (see `TxtQueryLane.forValve`'s doc comment) currently goes
/// unmet — this fills exactly that one slot, no wider, with whatever
/// address the OS already has configured for this connection (the same
/// one the phone's other apps already send their DNS queries to).
///
/// Returns `[]` whenever [existingSystemResolvers] is already non-empty
/// (desktop/CI: resolv.conf already answered, nothing to add) or
/// [probe] is unset (the demo/test build: no native binding, the same
/// seam [buildLocalLinkLane] uses). A [probe] that throws or answers
/// `null` is "not published right now", never a crash and never a
/// reason to fail the lane.
///
/// On a real device build, bind the platform's own DHCP-assigned
/// resolver into [probe] — one closure:
///
///   final resolvers = systemDnsResolverBinding(
///     existingSystemResolvers: TxtQueryResolvers.systemResolvers(),
///     probe: () => nativeSystemDnsResolver(),
///     // iOS: res_getservers() (libresolv) — first entry.
///     // Android: ConnectivityManager.getLinkProperties(activeNetwork)
///     //   .dnsServers.first.
///   );
List<HostPort> systemDnsResolverBinding({
  HostPort? Function()? probe,
  List<HostPort> existingSystemResolvers = const <HostPort>[],
}) {
  if (probe == null || existingSystemResolvers.isNotEmpty) {
    return const <HostPort>[];
  }
  try {
    return <HostPort>[?probe()];
  } catch (_) {
    return const <HostPort>[];
  }
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

/// Where a letter parked behind a down door waits between runs: the same
/// OS-backed Documents home the brains use on a phone, and the same
/// system-temp folder they fall back to elsewhere — which outlives a
/// process restart (the case that matters), not a reboot. No plugin.
Directory letterQueueDirectory() {
  final base =
      buildStorageDirectory()?.call() ??
      Directory('${Directory.systemTemp.path}/voice_call_kit_intelligence');
  return Directory('${base.path}/letters')..createSync(recursive: true);
}
