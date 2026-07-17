import 'dart:async';
import 'companion_service.dart';
import 'session_state_storage.dart';
import 'local_service_runner.dart';
import 'local_connection_verifier.dart';

/// Concrete implementation of [CompanionService] coordinating storage,
/// process execution, and network readiness checks.
class CompanionServiceImpl implements CompanionService {
  final SessionStateStorage _storage;
  final LocalServiceRunner _runner;
  final LocalConnectionVerifier _verifier;
  final String _host;
  final int _port;
  final Map<String, dynamic> _config;

  ServiceStatus _status = ServiceStatus.idle;

  /// Creates a new [CompanionServiceImpl] with its required collaborators.
  CompanionServiceImpl({
    required SessionStateStorage storage,
    required LocalServiceRunner runner,
    required LocalConnectionVerifier verifier,
    required String host,
    required int port,
    required Map<String, dynamic> config,
  }) : _storage = storage,
       _runner = runner,
       _verifier = verifier,
       _host = host,
       _port = port,
       _config = config;

  /// Returns the current lifecycle status of this service.
  ServiceStatus get status => _status;

  @override
  bool get isReady => _status == ServiceStatus.active && _runner.isActive;

  @override
  Future<void> prepare() async {
    if (_status != ServiceStatus.idle) return;

    _status = ServiceStatus.preparing;
    try {
      await _storage.save(_config);
    } catch (e) {
      _status = ServiceStatus.idle;
      rethrow;
    }
  }

  @override
  Future<bool> run() async {
    if (_status != ServiceStatus.preparing) {
      return _status == ServiceStatus.active;
    }

    try {
      await _runner.start();

      if (!_runner.isActive) {
        _status = ServiceStatus.stopped;
        return false;
      }

      final isHealthy = await _verifier.verifyServiceReadiness(_host, _port);
      if (isHealthy) {
        _status = ServiceStatus.active;
        return true;
      } else {
        await terminate();
        return false;
      }
    } catch (e) {
      await terminate();
      return false;
    }
  }

  @override
  Future<void> terminate() async {
    _status = ServiceStatus.stopped;
    try {
      await _runner.shutdown();
    } catch (_) {
      // Silent catch to ensure storage is closed even if runner shutdown fails
    }
    try {
      await _storage.close();
    } catch (_) {
      // Silent catch
    }
  }
}
