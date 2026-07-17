/// Lifecycle status of the local companion service.
enum ServiceStatus {
  idle,
  preparing,
  active,
  stopped,
}

/// Abstract contract for a local companion service.
abstract class CompanionService {
  /// Prepares the service before it can run.
  Future<void> prepare();

  /// Runs the service; returns true on success.
  Future<bool> run();

  /// Terminates the service and releases its resources.
  Future<void> terminate();

  /// Whether the service is prepared and ready to run.
  bool get isReady;
}
