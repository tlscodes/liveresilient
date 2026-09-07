// Dials the dev relay exactly the way the app's dev entry point does —
// connectWebSocketWithCustomRules with the platform resolver and the
// loopback-only certificate relaxer — and reports what happened, so a
// "Could not reconnect" on the call screen can be traced to the socket.
//
//   cd apps/reference_app && dart run tool/probe_relay.dart [wss://host:port/ ...]

// ignore_for_file: avoid_print

import 'dart:io';

import 'package:reference_app/src/ws_connector.dart';

Future<void> main(List<String> args) async {
  final targets = args.isEmpty
      ? const ['wss://localhost:4443/', 'wss://127.0.0.1:4443/']
      : args;
  for (final target in targets) {
    final started = DateTime.now();
    try {
      final socket = await connectWebSocketWithCustomRules(
        Uri.parse(target),
        hostResolver: platformHostResolution,
        badCertificateCallback: (certificate, host, port) =>
            isLoopbackHost(host),
      );
      print(
        'OK   $target in ${DateTime.now().difference(started).inMilliseconds} ms '
        '(readyState=${socket.readyState})',
      );
      await socket.close();
    } on Object catch (error) {
      print(
        'FAIL $target after ${DateTime.now().difference(started).inMilliseconds} ms: '
        '${error.runtimeType}: $error',
      );
    }
  }
  exit(0);
}
