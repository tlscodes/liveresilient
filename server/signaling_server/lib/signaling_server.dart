/// Minimal `wss://` signaling relay: pairs sockets by `callId` and forwards
/// opaque frames between them without parsing or trusting their contents.
library;

export 'src/dev_certificate.dart';
export 'src/relay_server.dart';
