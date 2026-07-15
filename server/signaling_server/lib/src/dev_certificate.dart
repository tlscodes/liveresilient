/// Local development TLS certificate helper.
///
/// [SignalingRelayServer] only accepts `wss://`, so both the CLI entrypoint
/// and the test suite need a certificate/key pair. This shells out to the
/// system `openssl` binary to generate a self-signed localhost certificate,
/// idempotently (an existing pair in the target directory is reused as-is).
library;

import 'dart:io';

/// Paths to a generated (or reused) self-signed dev certificate and key.
class DevCertificateFiles {
  const DevCertificateFiles({
    required this.certificatePath,
    required this.privateKeyPath,
  });

  final String certificatePath;
  final String privateKeyPath;
}

/// Ensures a self-signed `localhost` certificate/key pair exists under
/// [directoryPath], generating one with `openssl` if absent. Safe to call
/// repeatedly — an existing pair is left untouched and its paths returned.
Future<DevCertificateFiles> ensureDevCertificate({
  String directoryPath = '.dev-certs',
  String commonName = 'localhost',
}) async {
  final dir = Directory(directoryPath);
  if (!dir.existsSync()) {
    dir.createSync(recursive: true);
  }

  final certPath = '${dir.path}/dev-cert.pem';
  final keyPath = '${dir.path}/dev-key.pem';
  final certFile = File(certPath);
  final keyFile = File(keyPath);

  if (certFile.existsSync() && keyFile.existsSync()) {
    return DevCertificateFiles(
      certificatePath: certPath,
      privateKeyPath: keyPath,
    );
  }

  final result = await Process.run('openssl', [
    'req',
    '-x509',
    '-newkey',
    'rsa:2048',
    '-keyout',
    keyPath,
    '-out',
    certPath,
    '-days',
    '3650',
    '-nodes',
    '-subj',
    '/CN=$commonName',
    '-addext',
    'subjectAltName=DNS:$commonName,IP:127.0.0.1',
  ]);

  if (result.exitCode != 0) {
    throw StateError(
      'openssl failed to generate a dev certificate '
      '(exit ${result.exitCode}): ${result.stderr}',
    );
  }

  return DevCertificateFiles(
    certificatePath: certPath,
    privateKeyPath: keyPath,
  );
}
