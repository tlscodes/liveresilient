/// Dev/ops CLI: signs an `signed_config` [EndpointManifest] with an Ed25519
/// private key produced by `manifest_keygen.dart`.
///
/// ```
/// dart run bin/sign_manifest.dart \
///   --manifest manifest.json \
///   --key private-key.json \
///   [--out signed-manifest.json]
/// ```
///
/// `--manifest` is a JSON object with the [EndpointManifest] fields (see
/// `endpoint_manifest.dart`'s `fromJson`/`toJson`); any `signingKeyId` it
/// already contains is overwritten with the signing key's id, so the
/// signature and the id that names it never disagree.
///
/// The manifest is round-tripped through [EndpointManifest.fromJson] before
/// signing, so timestamps are always re-emitted exactly as Dart's
/// `toIso8601String()` would produce them — the same canonicalization the
/// app-side verifier expects (see [EndpointManifest.canonicalBytes]) — even
/// if the input file used a different (but equivalent) ISO-8601 spelling.
///
/// Output is the wire transport format consumed by
/// `SignedManifestDocument.fromBytes`: `{"manifest": {...}, "signature":
/// "<base64>"}`. Written to `--out` if given, otherwise to stdout.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:signed_config/signed_config.dart';

Future<void> main(List<String> args) async {
  String? manifestPath;
  String? keyPath;
  String? outPath;

  var i = 0;
  while (i < args.length) {
    final arg = args[i];
    if (arg == '--manifest' && i + 1 < args.length) {
      manifestPath = args[i + 1];
      i += 2;
    } else if (arg == '--key' && i + 1 < args.length) {
      keyPath = args[i + 1];
      i += 2;
    } else if (arg == '--out' && i + 1 < args.length) {
      outPath = args[i + 1];
      i += 2;
    } else {
      stderr.writeln('Unknown or incomplete argument: $arg');
      exitCode = 64;
      return;
    }
  }

  if (manifestPath == null || keyPath == null) {
    stderr.writeln(
      'Usage: dart run bin/sign_manifest.dart --manifest <manifest.json> '
      '--key <private-key.json> [--out <signed-manifest.json>]',
    );
    exitCode = 64;
    return;
  }

  final Object? manifestRaw;
  try {
    manifestRaw = jsonDecode(await File(manifestPath).readAsString());
  } on Exception catch (e) {
    stderr.writeln('Could not read manifest file: $e');
    exitCode = 66;
    return;
  }
  if (manifestRaw is! Map<String, Object?>) {
    stderr.writeln('Manifest file must contain a JSON object.');
    exitCode = 65;
    return;
  }

  final Object? keyRaw;
  try {
    keyRaw = jsonDecode(await File(keyPath).readAsString());
  } on Exception catch (e) {
    stderr.writeln('Could not read key file: $e');
    exitCode = 66;
    return;
  }
  if (keyRaw is! Map<String, Object?>) {
    stderr.writeln('Key file must contain a JSON object.');
    exitCode = 65;
    return;
  }
  final keyId = keyRaw['keyId'];
  final seedB64 = keyRaw['privateKeySeed'];
  if (keyId is! String || keyId.isEmpty) {
    stderr.writeln('Key file requires a non-empty "keyId" string.');
    exitCode = 65;
    return;
  }
  if (seedB64 is! String) {
    stderr.writeln('Key file requires a "privateKeySeed" base64 string.');
    exitCode = 65;
    return;
  }

  // The signing key is the source of truth for signingKeyId: the signature
  // it produces must always match the key id that names it, regardless of
  // whatever placeholder (if any) the input manifest file carried.
  final manifestJson = <String, Object?>{...manifestRaw, 'signingKeyId': keyId};

  final EndpointManifest manifest;
  try {
    manifest = EndpointManifest.fromJson(manifestJson);
  } on FormatException catch (e) {
    stderr.writeln('Invalid manifest: ${e.message}');
    exitCode = 65;
    return;
  }

  final Uint8List seed;
  try {
    seed = base64Decode(seedB64);
  } on FormatException {
    stderr.writeln('privateKeySeed is not valid base64.');
    exitCode = 65;
    return;
  }
  if (seed.length != 32) {
    stderr.writeln(
      'Ed25519 private key seeds are 32 bytes, got ${seed.length}.',
    );
    exitCode = 65;
    return;
  }

  final algorithm = Ed25519();
  final keyPair = await algorithm.newKeyPairFromSeed(seed);
  final message = Uint8List.fromList(manifest.canonicalBytes());
  final signature = await algorithm.sign(message, keyPair: keyPair);

  final signedDocument = <String, Object?>{
    'manifest': manifest.toJson(),
    'signature': base64Encode(signature.bytes),
  };
  final output =
      '${const JsonEncoder.withIndent('  ').convert(signedDocument)}\n';

  if (outPath != null) {
    await File(outPath).writeAsString(output);
    stdout.writeln('Signed manifest written to: $outPath');
  } else {
    stdout.write(output);
  }
}
