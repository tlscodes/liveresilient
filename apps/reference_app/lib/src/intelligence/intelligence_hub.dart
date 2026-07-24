/// The wiring loom: composes the learning models, their persistence, the
/// place resolver, and the assistant into one app-level unit with a
/// single lifecycle.
///
/// Restores both brains from disk on start, autosaves them debounced as
/// they learn, feeds the fabric's place() from the cached network label,
/// and hands the UI one assistant that is LLM-backed when a verified
/// model is present and rule-based otherwise.
library;

import 'package:connection_orchestrator/connection_orchestrator.dart';
import 'package:on_device_assistant/on_device_assistant.dart';

import 'disk_json_storage.dart';
import 'network_name_resolver.dart';

/// One composed intelligence stack.
class IntelligenceHub {
  IntelligenceHub._({
    required this.experience,
    required this.learner,
    required this.assistant,
    required this.resolver,
    required this._experienceSaver,
    required this._learnerSaver,
  });

  /// Restores persisted state and initializes the assistant tier.
  static Future<IntelligenceHub> start({
    required PersistentStorage experienceStorage,
    required PersistentStorage learnerStorage,
    required CachingNetworkResolver resolver,
    LlmEngine? llmEngine,
  }) async {
    final experience = LaneExperience.fromJson(await experienceStorage.load());
    final learner = MicroLearner.fromJson(await learnerStorage.load());
    final OnDeviceAssistant assistant = llmEngine == null
        ? RuleBasedAssistant()
        : LlmBackedAssistant(engine: llmEngine);
    await assistant.initialize();
    return IntelligenceHub._(
      experience: experience,
      learner: learner,
      assistant: assistant,
      resolver: resolver,
      experienceSaver: DebouncedSaver(
        storage: experienceStorage,
        snapshot: experience.toJson,
      ),
      learnerSaver: DebouncedSaver(
        storage: learnerStorage,
        snapshot: learner.toJson,
      ),
    );
  }

  /// Persistent contextual delivery memory — pass to [ConnectionFabric].
  final LaneExperience experience;

  /// Persistent place-network map.
  final MicroLearner learner;

  /// User-facing language tier (LLM when available, rules otherwise).
  final OnDeviceAssistant assistant;

  /// Feeds `ConnectionFabric(place: hub.placeResolver)`.
  final CachingNetworkResolver resolver;

  final DebouncedSaver _experienceSaver;
  final DebouncedSaver _learnerSaver;

  /// Synchronous place label for the fabric's hot path.
  String placeResolver() => resolver.lastKnownLabel;

  /// Feed one observed sample into the long-term map (called from the
  /// path monitor's evaluation loop) and schedule persistence.
  void recordObservation({
    required double quality,
    required double slope,
    required int nowMs,
  }) {
    learner.observe(
      ConnectivityExperience(
        placeTag: resolver.lastKnownLabel,
        networkName: resolver.lastKnownLabel,
        quality: quality,
        slope: slope,
        atMs: nowMs,
      ),
    );
    _learnerSaver.markDirty();
  }

  /// Call after deliveries so the contextual memory reaches disk too.
  void markExperienceDirty() => _experienceSaver.markDirty();

  /// Flush both brains (app pause) without tearing down.
  Future<void> flush() async {
    await _experienceSaver.flush();
    await _learnerSaver.flush();
  }

  Future<void> dispose() async {
    await _experienceSaver.dispose();
    await _learnerSaver.dispose();
    await assistant.dispose();
  }
}
