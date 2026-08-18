/// Resolves the device's current network identity into the coarse place
/// label the learning models key on.
///
/// The hardware probes (Wi-Fi name, connectivity type, carrier name) are
/// injected closures: `connectivity_plus`/`network_info_plus` bind here
/// with one line each in main.dart, tests inject fakes, and no plugin
/// type ever leaks into the learning layer. Results are TTL-cached so a
/// per-delivery lookup costs nothing.
library;

/// Broad transport the device is on right now.
enum NetworkTransport { wifi, cellular, ethernet, none }

/// Abstract seam for the learning layer.
abstract interface class NetworkNameResolver {
  /// A stable, coarse label for the current network ("HomeNet-5G",
  /// "carrier:vodafone", "offline") — never a precise location.
  Future<String> resolveNetworkLabel();
}

/// Hardware-backed resolver over injected probes, with graceful fallbacks.
class HardwareNetworkResolver implements NetworkNameResolver {
  HardwareNetworkResolver({
    required this._transportProbe,
    this._wifiNameProbe,
    this._carrierNameProbe,
  });

  final Future<NetworkTransport> Function() _transportProbe;
  final Future<String?> Function()? _wifiNameProbe;
  final Future<String?> Function()? _carrierNameProbe;

  @override
  Future<String> resolveNetworkLabel() async {
    try {
      switch (await _transportProbe()) {
        case NetworkTransport.wifi:
          final name = await _wifiNameProbe?.call();
          // SSID probes return null without location permission — the
          // label stays useful, just less specific.
          return name == null || name.isEmpty ? 'wifi:unnamed' : 'wifi:$name';
        case NetworkTransport.cellular:
          final carrier = await _carrierNameProbe?.call();
          return carrier == null || carrier.isEmpty
              ? 'cellular:unknown'
              : 'cellular:$carrier';
        case NetworkTransport.ethernet:
          return 'ethernet';
        case NetworkTransport.none:
          return 'offline';
      }
    } catch (_) {
      return 'unresolved'; // A probe crash never propagates.
    }
  }
}

/// TTL cache so hot paths (every delivery) reuse the last resolution.
class CachingNetworkResolver implements NetworkNameResolver {
  CachingNetworkResolver(
    this._inner, {
    required this._nowMs,
    this.ttlMs = 15000,
  });

  final NetworkNameResolver _inner;
  final int Function() _nowMs;
  final int ttlMs;

  /// Fired when a resolve lands on a DIFFERENT label than the previous
  /// one — the network-transition seam («هوشمندی v4» pillar 4): the hub
  /// wires this to NetworkAtlas.recordTransition so lane pre-warming can
  /// know where this network usually goes next. Never fired for the
  /// first-ever resolve (no from-side yet) or a same-label refresh.
  void Function(String from, String to)? onLabelChange;

  String? _cached;
  int _cachedAtMs = -1;

  /// Synchronous view for hot paths: last known label, resolving in the
  /// background when stale.
  String get lastKnownLabel => _cached ?? 'unresolved';

  /// Forces the next resolve to hit hardware (e.g. on connectivity-change
  /// events from the platform).
  void invalidate() => _cachedAtMs = -1;

  @override
  Future<String> resolveNetworkLabel() async {
    final now = _nowMs();
    if (_cached != null && _cachedAtMs >= 0 && now - _cachedAtMs < ttlMs) {
      return _cached!;
    }
    final label = await _inner.resolveNetworkLabel();
    final previous = _cached;
    _cached = label;
    _cachedAtMs = now;
    if (previous != null && previous != label) {
      onLabelChange?.call(previous, label);
    }
    return label;
  }
}
