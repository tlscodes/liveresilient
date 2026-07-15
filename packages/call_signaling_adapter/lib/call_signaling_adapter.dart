/// Bridges `call_core`'s transport-agnostic `CallSignaling`/`CallTransport`
/// interfaces onto the `signaling` package's `SignalingClient`.
///
/// `call_core` and `signaling` have deliberately independent type systems;
/// this package is the only place they meet.
library;

export 'src/adapter_call_signaling.dart';
export 'src/adapter_call_transport.dart';
export 'src/envelope_codec.dart';
export 'src/signaling_gateway.dart';
