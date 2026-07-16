/// Dev/ops CLI: generates an Ed25519 signing keypair for `signed_config`
/// manifests.
///
/// ```
/// dart run bin/manifest_keygen.dart --out private-key.json [--key-id key-1]
/// ```
///
/// Prints the key id and base64 public key to stdout (the public key is
/// what gets pinned into the app build as a [PinnedManifestKey]) and writes
/// the private key material as JSON to `--out`.
///
/// WARNING: the `--out` file contains raw Ed25519 private key bytes. This
/// tool is a development/ops convenience for generating and rotating keys
/// out of band, not a vault. Treat the output file like a production
/// secret: never commit it, restrict its filesystem permissions, and
/// prefer an HSM/KMS-backed signing process for real deployments.
library;

import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';

Future<void> main(List<String> args) async {
  String? outPath;
  String? keyId;

  var i = 0;
  while (i < args.length) {
    final arg = args[i];
    if (arg == '--out' && i + 1 < args.length) {
      outPath = args[i + 1];
      i += 2;
    } else if (arg == '--key-id' && i + 1 < args.length) {
      keyId = args[i + 1];
      i += 2;
    } else {
      stderr.writeln('Unknown or incomplete argument: $arg');
      exitCode = 64;
      return;
    }
  }

  if (outPath == null) {
    stderr.writeln(
      'Usage: dart run bin/manifest_keygen.dart --out <private-key.json> '
      '[--key-id <id>]',
    );
    exitCode = 64;
    return;
  }

  final algorithm = Ed25519();
  final keyPair = await algorithm.newKeyPair();
  final seed = await keyPair.extractPrivateKeyBytes();
  final publicKey = await keyPair.extractPublicKey();
  final resolvedKeyId =
      keyId ?? 'key-${DateTime.now().toUtc().microsecondsSinceEpoch}';
  final publicKeyB64 = base64Encode(publicKey.bytes);

  final privateKeyJson = <String, Object?>{
    'keyId': resolvedKeyId,
    'algorithm': 'ed25519',
    'privateKeySeed': base64Encode(seed),
    'publicKey': publicKeyB64,
  };

  final outFile = File(outPath);
  await outFile.create(recursive: true);
  await outFile.writeAsString(
    '${const JsonEncoder.withIndent('  ').convert(privateKeyJson)}\n',
  );

  stdout.writeln('keyId: $resolvedKeyId');
  stdout.writeln('publicKey (base64): $publicKeyB64');
  stdout.writeln('Private key written to: $outPath');
  stdout.writeln();
  stdout.writeln(
    'WARNING: that file contains raw Ed25519 private key material. Keep it '
    'out of version control, restrict its file permissions, and prefer an '
    'HSM/KMS for production signing. This CLI is a dev/ops convenience, '
    'not a vault.',
  );
}
