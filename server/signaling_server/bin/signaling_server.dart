/// CLI entrypoint for the minimal signaling relay.
///
/// Usage:
///   dart run bin/signaling_server.dart [--port 8443] [--cert-dir .dev-certs]
///       [--address 0.0.0.0]
///
/// `--address` defaults to loopback (the library's safe default). The T2 rig
/// passes the Mac's bridge address so a phone on bridge100 can reach it —
/// without it the relay silently listens on 127.0.0.1 only and every remote
/// client dies in `reconnecting`.
library;

import 'dart:io';

import 'package:signaling_server/signaling_server.dart';

Future<void> main(List<String> arguments) async {
  final options = _CliOptions.parse(arguments);

  final certificate = await ensureDevCertificate(
    directoryPath: options.certDir,
  );
  final security = SecurityContext()
    ..useCertificateChain(certificate.certificatePath)
    ..usePrivateKey(certificate.privateKeyPath);

  final server = await SignalingRelayServer.bind(
    security: security,
    address: options.address,
    port: options.port,
    logSink: (event, {callId, error}) {
      final suffix = error != null ? ' error=$error' : '';
      stderr.writeln(
        '[signaling_server] $event'
        '${callId != null ? ' callId=$callId' : ''}$suffix',
      );
    },
  );

  final shownHost = options.address?.address ?? 'localhost';
  stdout.writeln('listening on wss://$shownHost:${server.port}');

  await ProcessSignal.sigint.watch().first;
  stdout.writeln('shutting down');
  await server.close();
}

class _CliOptions {
  const _CliOptions({
    required this.port,
    required this.certDir,
    required this.address,
  });

  final int port;
  final String certDir;

  /// Null = library default (loopback only).
  final InternetAddress? address;

  static _CliOptions parse(List<String> arguments) {
    var port = 8443;
    var certDir = '.dev-certs';
    InternetAddress? address;

    for (var i = 0; i < arguments.length; i++) {
      final arg = arguments[i];
      String? value;
      String flag;
      final eq = arg.indexOf('=');
      if (arg.startsWith('--') && eq != -1) {
        flag = arg.substring(0, eq);
        value = arg.substring(eq + 1);
      } else {
        flag = arg;
        if (i + 1 < arguments.length) {
          value = arguments[i + 1];
          i++;
        }
      }

      switch (flag) {
        case '--port':
          if (value != null) port = int.parse(value);
        case '--cert-dir':
          if (value != null) certDir = value;
        case '--address':
          if (value != null) {
            address = value == 'any'
                ? InternetAddress.anyIPv4
                : InternetAddress(value);
          }
        default:
          stderr.writeln('unknown argument: $flag');
      }
    }

    return _CliOptions(port: port, certDir: certDir, address: address);
  }
}
