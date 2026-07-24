/// Boot wiring: composes the whole intelligence circuit at app start.
///
/// Every hardware/plugin probe and the LLM engine are injectable with
/// safe defaults, so the same boot path serves the standalone demo, unit
/// tests, and a real device build (where main.dart passes the plugin
/// closures and a [GemmaLlmEngine]).
library;

import 'dart:io';

import 'package:adaptive_transport/adaptive_transport.dart';
import 'package:connection_orchestrator/connection_orchestrator.dart';
import 'package:device_link/device_link.dart' show DtnBundleQueue;
import 'package:on_device_assistant/on_device_assistant.dart';

import 'disk_json_storage.dart';
import 'intelligence_director.dart';
import 'intelligence_hub.dart';
import 'network_name_resolver.dart';

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
  LlmEngine? llmEngine,
  TransportChannel? primaryLane,
  int Function()? nowMs,
}) async {
  final dirFactory = storageDirFactory ?? _defaultIntelligenceDir;
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
    resolver: resolvedResolver,
    llmEngine: llmEngine,
  );

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
