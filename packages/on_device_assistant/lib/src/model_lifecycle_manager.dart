/// Model download and lifecycle policy: a multi-gigabyte model file must
/// never hurt the user's data plan, battery, or trust.
///
/// Pure logic: the actual byte transfer, connectivity flags, and hashing
/// are injected, so every branch is unit-testable and the same manager
/// drives any engine's model file.
library;

import 'dart:async';

/// Why a download is currently not allowed (empty list = allowed).
enum DownloadBlocker { alreadyPresent, notOnUnmeteredNetwork, notCharging }

/// Progress of one model acquisition.
class ModelDownloadProgress {
  const ModelDownloadProgress({
    required this.receivedBytes,
    required this.totalBytes,
  });

  final int receivedBytes;
  final int totalBytes;

  double get fraction => totalBytes <= 0 ? 0 : receivedBytes / totalBytes;
}

/// Terminal result of an acquisition attempt.
enum ModelAcquisitionResult { ready, blocked, checksumMismatch, fetchFailed }

/// Injected environment: what the device reports right now.
class DevicePowerNetworkState {
  const DevicePowerNetworkState({
    required this.onUnmeteredNetwork,
    required this.charging,
  });

  final bool onUnmeteredNetwork;
  final bool charging;
}

/// Manages when a model may be downloaded and verifies it before use.
class ModelLifecycleManager {
  ModelLifecycleManager({
    required this.expectedChecksum,
    this.requireCharging = true,
  });

  /// Content hash the downloaded file must match before it is ever
  /// loaded into memory (integrity, not security theater: a truncated
  /// 2 GB download must not crash the inference runtime).
  final String expectedChecksum;

  /// Large downloads wait for charging by default.
  final bool requireCharging;

  final _progress = StreamController<ModelDownloadProgress>.broadcast();

  /// UI-facing progress stream.
  Stream<ModelDownloadProgress> get progress => _progress.stream;

  /// Policy check: every blocker currently standing between the user and
  /// a download. Empty means "go".
  List<DownloadBlocker> blockers({
    required DevicePowerNetworkState device,
    required bool modelAlreadyPresent,
  }) => [
    if (modelAlreadyPresent) DownloadBlocker.alreadyPresent,
    if (!device.onUnmeteredNetwork) DownloadBlocker.notOnUnmeteredNetwork,
    if (requireCharging && !device.charging) DownloadBlocker.notCharging,
  ];

  /// Runs one acquisition attempt end to end: policy gate → injected
  /// fetch (reporting progress) → injected checksum verify.
  Future<ModelAcquisitionResult> acquire({
    required DevicePowerNetworkState device,
    required bool modelAlreadyPresent,
    required int totalBytes,
    required Future<void> Function(void Function(int receivedBytes) onProgress)
    fetch,
    required Future<String> Function() computeChecksum,
  }) async {
    if (blockers(
      device: device,
      modelAlreadyPresent: modelAlreadyPresent,
    ).isNotEmpty) {
      return ModelAcquisitionResult.blocked;
    }
    try {
      await fetch((received) {
        _progress.add(
          ModelDownloadProgress(
            receivedBytes: received,
            totalBytes: totalBytes,
          ),
        );
      });
    } catch (_) {
      return ModelAcquisitionResult.fetchFailed;
    }
    final actual = await computeChecksum();
    if (actual != expectedChecksum) {
      return ModelAcquisitionResult.checksumMismatch;
    }
    return ModelAcquisitionResult.ready;
  }

  Future<void> dispose() => _progress.close();
}
