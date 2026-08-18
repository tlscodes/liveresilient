/// Boot wiring: composes the whole intelligence circuit at app start.
///
/// Every hardware/plugin probe is injectable with safe defaults, so the
/// same boot path serves the standalone demo, unit tests, and a real
/// device build (where main.dart passes the plugin closures).
library;

import 'dart:io';

import 'package:adaptive_transport/adaptive_transport.dart';
import 'package:connection_orchestrator/connection_orchestrator.dart';
import 'package:device_link/device_link.dart' show DtnBundleQueue;

import 'disk_json_storage.dart';
import 'intelligence_director.dart';
import 'intelligence_hub.dart';
import 'network_name_resolver.dart';
import 'nightly_evolution.dart';

/// The demo's always-available local lane: represents in-process loopback
/// delivery so the standalone app has one honest live lane.
class _LoopbackChannel implements TransportChannel {
  @override
  String get name => 'local-demo';

  @override
  final ChannelHealth health = ChannelHealth(
    reliabilityPrior: 0.99,
    bandwidth: 1.0,
    rttMs: 5,
  );

  @override
  Future<bool> probe() async => true;

  @override
  Future<SendResult> send(List<int> payload) async =>
      const SendResult(SendStatus.ok, rttMs: 5);

  @override
  Future<void> dispose() async {}
}

/// Everything the app layer needs, born together, disposed together.
class IntelligenceStack {
  IntelligenceStack._(this.hub, this.fabric, this.director);

  final IntelligenceHub hub;
  final ConnectionFabric fabric;
  final IntelligenceDirector director;

  /// The five persisted brains, surfaced for wiring and tests.
  NetworkAtlas get atlas => hub.atlas;
  LaneChoicePolicy get laneChoice => hub.laneChoice;
  BudgetCalibrator get calibrator => hub.calibrator;
  MeasurementJournal get journal => hub.journal;
  CallHistoryStore get history => hub.history;

  Future<void> dispose() async {
    director.dispose();
    await fabric.dispose();
    await hub.dispose();
  }
}

/// Boots the circuit: restore brains → build fabric (place-aware,
/// persistent experience) → seed lane ranking from place memory → start
/// the director.
Future<IntelligenceStack> bootIntelligence({
  Directory Function()? storageDirFactory,
  CachingNetworkResolver? resolver,
  TransportChannel? primaryLane,
  TransportChannel? localLinkLane,
  int Function()? nowMs,
}) async {
  final dirFactory = storageDirFactory ?? _defaultIntelligenceDir;
  // A nightly round may have staged a promoted brain generation
  // (v4 pillar 3): install it BEFORE the hub loads its files, so the
  // promoted brains are what wake up. No candidate -> no-op.
  await applyStagedGeneration(dirFactory());
  final resolvedResolver =
      resolver ??
      CachingNetworkResolver(
        HardwareNetworkResolver(
          transportProbe: () async => NetworkTransport.wifi,
        ),
        nowMs: nowMs ?? () => DateTime.now().millisecondsSinceEpoch,
      );
  await resolvedResolver.resolveNetworkLabel();

  final hub = await IntelligenceHub.start(
    experienceStorage: DiskJsonStorage(
      directoryFactory: dirFactory,
      fileName: 'lane_experience.json',
    ),
    learnerStorage: DiskJsonStorage(
      directoryFactory: dirFactory,
      fileName: 'place_map.json',
    ),
    atlasStorage: DiskJsonStorage(
      directoryFactory: dirFactory,
      fileName: 'network_atlas.json',
    ),
    laneChoiceStorage: DiskJsonStorage(
      directoryFactory: dirFactory,
      fileName: 'lane_choice.json',
    ),
    calibratorStorage: DiskJsonStorage(
      directoryFactory: dirFactory,
      fileName: 'budget_calibrator.json',
    ),
    journalStorage: DiskJsonStorage(
      directoryFactory: dirFactory,
      fileName: 'measurement_journal.json',
    ),
    historyStorage: DiskJsonStorage(
      directoryFactory: dirFactory,
      fileName: 'call_history.json',
    ),
    resolver: resolvedResolver,
    nowMs: nowMs ?? () => DateTime.now().millisecondsSinceEpoch,
  );
  // Network hops become pre-warm knowledge (v4 pillar 4): every label
  // change the resolver observes trains the atlas's transition model.
  resolvedResolver.onLabelChange = (from, to) =>
      hub.noteNetworkChange(fromLabel: from, toLabel: to);

  final fabric = ConnectionFabric(
    fallbackQueue: DtnBundleQueue(),
    nowMs: nowMs ?? () => DateTime.now().millisecondsSinceEpoch,
    experience: hub.experience,
    place: hub.placeResolver,
  );
  final lane = primaryLane ?? _LoopbackChannel();
  fabric.registerLane(
    lane,
    LaneProfile(id: lane.name, kind: LaneKind.internet),
  );
  // Local peer-to-peer lane: registered when the platform provides a link
  // radio, so the fabric fails over to a direct nearby-device link the
  // moment internet lanes die. costRank 1 keeps it slightly behind free
  // internet at equal health, but a healthier link still wins.
  if (localLinkLane != null) {
    fabric.registerLane(
      localLinkLane,
      LaneProfile(
        id: localLinkLane.name,
        kind: LaneKind.localPeer,
        costRank: 1,
      ),
    );
  }
  // Arriving where we've been before: pre-rank from the long-term map.
  fabric.applyPlaceForecast(
    hub.learner,
    hub.placeResolver(),
    networkOfLane: (_) => hub.placeResolver(),
  );

  final director = IntelligenceDirector(fabric: fabric, hub: hub);
  return IntelligenceStack._(hub, fabric, director);
}

Directory _defaultIntelligenceDir() {
  final dir = Directory(
    '${Directory.systemTemp.path}/voice_call_kit_intelligence',
  );
  if (!dir.existsSync()) dir.createSync(recursive: true);
  return dir;
}
