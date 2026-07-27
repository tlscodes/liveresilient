import '../circuit_breaker.dart';
import '../path_selector.dart';
import '../transport_channel.dart';

/// Builds a [PathSelector] over the standard resilient-delivery lane stack,
/// in priority order: primary UDP → WebSocket relay → HTTPS long-poll →
/// local mesh peer. Each lane is optional (pass `null` to omit it, e.g. no
/// mesh peer currently available); only the non-null lanes, in the order
/// given, are handed to the selector.
///
/// This class does not reimplement ranking, failover, or circuit-breaking —
/// [PathSelector] already owns that. It is a thin composition point so
/// callers assemble the four standards-based lanes without hand-wiring the
/// selector themselves.
class ResilientFallbackTransportChain {
  ResilientFallbackTransportChain._();

  static PathSelector build({
    TransportChannel? primaryUdp,
    TransportChannel? webSocketRelay,
    TransportChannel? httpLongPoll,
    TransportChannel? localMesh,
    RouterConfig config = const RouterConfig(),
    CircuitBreakerConfig breakerConfig = const CircuitBreakerConfig(),
  }) {
    final channels = <TransportChannel>[
      if (primaryUdp != null) primaryUdp,
      if (webSocketRelay != null) webSocketRelay,
      if (httpLongPoll != null) httpLongPoll,
      if (localMesh != null) localMesh,
    ];

    if (channels.isEmpty) {
      throw ArgumentError(
        'At least one lane must be provided to build a resilient chain.',
      );
    }

    return PathSelector(
      channels,
      config: config,
      breakerConfig: breakerConfig,
    );
  }
}
