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

/// Where the intelligence brains persist their JSON files — pure and
/// injectable, so the path logic is unit-testable with real path strings
/// and no disk access.
///
/// iOS: the app container's `Documents` is the OS-backed persistent store
/// (survives relaunches, not purgeable the way `tmp` is). It is the sibling
/// of the container's temp folder, so it is derived from [systemTempPath] —
/// `NSTemporaryDirectory()` is always set, whereas `HOME` is empty under
/// some launchers (e.g. `devicectl`), which used to drop the whole brains
/// folder — queue included — into purgeable `tmp`.
/// Android: unchanged — `$HOME/Documents`, or `null` when `HOME` is unset.
/// The cache dir's persistent sibling is `files`, NOT `Documents`, so the
/// iOS sibling trick must not be applied here.
/// Everywhere else (tests, desktop dev): `null`, so `bootIntelligence`
/// keeps its system-temp default. Pure Dart, zero plugins (CI-safety rule).
String? intelligenceStorageBase({
  required bool isIOS,
  required bool isAndroid,
  required String systemTempPath,
  required Map<String, String> environment,
}) {
  if (isIOS) {
    final tmp = systemTempPath.replaceAll(RegExp(r'/+$'), '');
    final cut = tmp.lastIndexOf('/');
    if (cut <= 0) return null;
    return '${tmp.substring(0, cut)}/Documents/voice_call_kit_intelligence';
  }
  if (isAndroid) {
    final home = environment['HOME'];
    if (home == null || home.isEmpty) return null;
    return '$home/Documents/voice_call_kit_intelligence';
  }
  return null;
}

/// The directory factory `bootIntelligence` injects: the persistent base on
/// a phone (created on first use), or `null` when this build has none.
Directory Function()? buildStorageDirectory() {
  final base = intelligenceStorageBase(
    isIOS: Platform.isIOS,
    isAndroid: Platform.isAndroid,
    systemTempPath: Directory.systemTemp.path,
    environment: Platform.environment,
  );
  if (base == null) return null;
  final docs = Directory(base);
  return () => docs..createSync(recursive: true);
}

/// The folder the parked-letter queue, the per-letter measurement card and
/// the identity file share: the persistent base on a phone,
/// `Library/Application Support` on a Mac ([identityStorageBase]), and the
/// system-temp folder elsewhere and under `flutter test`. The brains keep
/// `bootIntelligence`'s own default; they are rebuilt from what they
/// measure, a parked letter is not.
///
/// A Mac used to keep all of this in the temp folder. The first call here
/// carries the queue and the card file over once ([adoptDesktopFiles]):
/// copied, never over a file already there, the old ones left in place.
Directory intelligenceStorageDirectory() {
  final phone = buildStorageDirectory();
  if (phone != null) return phone();
  final base = identityStorageBase(
    isMacOS: Platform.isMacOS,
    environment: Platform.environment,
  );
  if (base == null) return legacyDesktopStorageDirectory();
  final home = Directory(base)..createSync(recursive: true);
  if (!_desktopFilesAdopted) {
    _desktopFilesAdopted = true;
    adoptDesktopFiles(from: legacyDesktopStorageDirectory(), to: home);
  }
  return home;
}

bool _desktopFilesAdopted = false;

/// Where a desktop kept these files before they had a persistent home, and
/// where a host with no such home still keeps them.
Directory legacyDesktopStorageDirectory() =>
    Directory('${Directory.systemTemp.path}/voice_call_kit_intelligence');

/// Copies the card file and every parked letter from [from] into [to] when
/// [to] does not have them yet. Never overwrites, never deletes; a failure
/// is swallowed, because losing the carry-over must not stop the app.
/// Returns how many files it copied.
int adoptDesktopFiles({required Directory from, required Directory to}) {
  var copied = 0;
  try {
    if (from.path == to.path || !from.existsSync()) return 0;
    void carry(File old, File now) {
      if (!old.existsSync() || now.existsSync()) return;
      now.parent.createSync(recursive: true);
      old.copySync(now.path);
      copied++;
    }

    carry(
      File('${from.path}/letter_cards.jsonl'),
      File('${to.path}/letter_cards.jsonl'),
    );
    final letters = Directory('${from.path}/letters');
    if (letters.existsSync()) {
      for (final entry in letters.listSync(followLinks: false)) {
        if (entry is! File) continue;
        final name = entry.uri.pathSegments.last;
        carry(entry, File('${to.path}/letters/$name'));
      }
    }
  } catch (_) {
    // Best effort.
  }
  return copied;
}

/// Where this install's public id and its pinned peer keys live on a Mac:
/// `Library/Application Support` under `HOME`, which inside the app sandbox
/// is the app's own container. The system-temp folder the other
/// intelligence files default to on a desktop is purgeable, and an install
/// that loses this file comes back as a stranger to every peer that pinned
/// it. `null` everywhere else — a phone's intelligence folder is already
/// persistent — and under `flutter test`, which must not write into the
/// developer's home.
String? identityStorageBase({
  required bool isMacOS,
  required Map<String, String> environment,
}) {
  if (!isMacOS || environment.containsKey('FLUTTER_TEST')) return null;
  final home = environment['HOME'];
  if (home == null || home.isEmpty) return null;
  final root = home.replaceAll(RegExp(r'/+$'), '');
  return '$root/Library/Application Support/voice_call_kit_intelligence';
}

/// The folder the identity file is kept in: the same one as the queue and
/// the card file, on every platform.
Directory identityStorageDirectory() => intelligenceStorageDirectory();

/// Where a letter parked behind a down door waits between runs: a `letters`
/// subfolder of [intelligenceStorageDirectory], created on first use. On a
/// phone this is the OS-backed Documents home (no `HOME` dependency), so a
/// parked letter outlives a process restart instead of landing in
/// purgeable `tmp`. No plugin.
Directory letterQueueDirectory() =>
    Directory('${intelligenceStorageDirectory().path}/letters')
      ..createSync(recursive: true);
