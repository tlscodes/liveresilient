/// Thin entrypoint for the fountain lane's datagram relay (RIG_GUIDE §0.3).
/// All logic lives in the testable class; this parses `--port` and prints
/// the readiness line the harness greps. Default 3737 — NOT 3479, which
/// coturn binds itself (alt-listening-port = listening-port + 1).
library;

import 'package:signaling_server/signaling_server.dart';

Future<void> main(List<String> args) async {
  var port = 3737;
  for (var i = 0; i + 1 < args.length; i++) {
    if (args[i] == '--port') port = int.parse(args[i + 1]);
  }
  final relay = await DatagramRelay.bind(port);
  print('datagram relay listening on 0.0.0.0:${relay.port}');
}
