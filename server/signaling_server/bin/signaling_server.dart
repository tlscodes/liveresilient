/// CLI entrypoint for the minimal signaling relay.
///
/// Usage:
///   dart run bin/signaling_server.dart [--port 8443] [--cert-dir .dev-certs]
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
    port: options.port,
    logSink: (event, {callId, error}) {
      final suffix = error != null ? ' error=$error' : '';
      stderr.writeln(
        '[signaling_server] $event'
        '${callId != null ? ' callId=$callId' : ''}$suffix',
      );
    },
  );

  stdout.writeln('listening on wss://localhost:${server.port}');

  await ProcessSignal.sigint.watch().first;
  stdout.writeln('shutting down');
  await server.close();
}

class _CliOptions {
  const _CliOptions({required this.port, required this.certDir});

  final int port;
  final String certDir;

  static _CliOptions parse(List<String> arguments) {
    var port = 8443;
    var certDir = '.dev-certs';

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
        default:
          stderr.writeln('unknown argument: $flag');
      }
    }

    return _CliOptions(port: port, certDir: certDir);
  }
}
