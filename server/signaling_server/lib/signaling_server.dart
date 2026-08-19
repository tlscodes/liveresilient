/// Minimal `wss://` signaling relay: pairs sockets by `callId` and forwards
/// opaque frames between them without parsing or trusting their contents.
library;

export 'src/abuse_controls.dart';
export 'src/datagram_relay.dart';
export 'src/dev_certificate.dart';
export 'src/relay_server.dart';
