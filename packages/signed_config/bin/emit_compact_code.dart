/// Dev/ops CLI: turns a signed manifest into the compact code a person can
/// carry — printed, photographed, pasted, or read aloud.
///
/// ```
/// dart run bin/emit_compact_code.dart \
///   --document signed-manifest.json \
///   [--out code.txt] [--verify]
/// ```
///
/// THE GAP THIS FILLS. `CompactManifestCode` can encode and decode, and the app
/// can import what it produces — but nothing on the OPERATIONS side could
/// produce one. A format that only the consumer can speak is not deployable:
/// the person who signs the manifest had no way to hand it to anyone except
/// over the network the code exists to avoid.
///
/// `--verify` decodes the code again and byte-compares it with the input. It is
/// on by default, because the failure this guards against is silent: a code
/// that encodes but does not decode would be discovered by a user in a blocked
/// network, which is the worst possible place to discover anything.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:signed_config/signed_config.dart';

Future<void> main(List<String> args) async {
  String? documentPath;
  String? outPath;
  var verify = true;
  var quiet = false;

  var i = 0;
  while (i < args.length) {
    final arg = args[i];
    if (arg == '--document' && i + 1 < args.length) {
      documentPath = args[i + 1];
      i += 2;
    } else if (arg == '--out' && i + 1 < args.length) {
      outPath = args[i + 1];
      i += 2;
    } else if (arg == '--no-verify') {
      verify = false;
      i += 1;
    } else if (arg == '--quiet') {
      quiet = true;
      i += 1;
    } else {
      stderr.writeln('Unknown or incomplete argument: $arg');
      stderr.writeln(
        'usage: emit_compact_code.dart --document <signed.json> '
        '[--out <file>] [--no-verify] [--quiet]',
      );
      exitCode = 64;
      return;
    }
  }

  if (documentPath == null) {
    stderr.writeln('--document is required (output of sign_manifest.dart)');
    exitCode = 64;
    return;
  }

  final bytes = await File(documentPath).readAsBytes();

  // Parse before encoding. A code is only useful if the app can verify what is
  // inside it, and a malformed document would produce a perfectly valid code
  // carrying garbage — an error that surfaces on a stranger's phone rather
  // than here.
  final SignedManifestDocument document;
  try {
    document = SignedManifestDocument.fromBytes(bytes);
  } on FormatException catch (e) {
    stderr.writeln('Not a signed manifest document: ${e.message}');
    exitCode = 65;
    return;
  }

  final EndpointManifest manifest;
  try {
    manifest = EndpointManifest.fromJson(document.manifestJson);
  } on FormatException catch (e) {
    stderr.writeln('Manifest inside the document is invalid: ${e.message}');
    exitCode = 65;
    return;
  }

  final String code;
  try {
    code = CompactManifestCode.encode(bytes);
  } on CompactDecodeException catch (e) {
    stderr.writeln('Cannot encode: ${e.error.name} — ${e.detail}');
    stderr.writeln(
      'A manifest this large should be delivered as a file, or signed with '
      'fewer origins and regions so it fits a code people can scan.',
    );
    exitCode = 65;
    return;
  }

  if (verify) {
    final Uint8List roundTripped;
    try {
      roundTripped = CompactManifestCode.decode(code);
    } on CompactDecodeException catch (e) {
      stderr.writeln('SELF-CHECK FAILED on decode: ${e.error.name}');
      exitCode = 70;
      return;
    }
    if (roundTripped.length != bytes.length) {
      stderr.writeln('SELF-CHECK FAILED: length differs after round trip');
      exitCode = 70;
      return;
    }
    for (var j = 0; j < bytes.length; j++) {
      if (roundTripped[j] != bytes[j]) {
        stderr.writeln('SELF-CHECK FAILED: byte $j differs after round trip');
        exitCode = 70;
        return;
      }
    }
  }

  if (outPath != null) {
    await File(outPath).writeAsString('$code\n');
  } else {
    stdout.writeln(code);
  }

  if (!quiet) {
    final chars = code.length;
    stderr.writeln(
      'revision ${manifest.revision} · key ${manifest.signingKeyId} · '
      '${manifest.iceServers.length} ICE servers · '
      'expires ${manifest.expiresAt.toIso8601String()}',
    );
    stderr.writeln(
      '$chars characters'
      '${verify ? ' · round-trip verified' : ' · NOT verified (--no-verify)'}',
    );
    // QR alphanumeric mode tops out near 4,296 characters at the lowest error
    // correction, and a code nobody can scan on a cracked screen in bad light
    // is a code that does not exist. Warn well before the hard ceiling.
    if (chars > 2500) {
      stderr.writeln(
        'WARNING: long for a scannable code. Consider signing a manifest with '
        'fewer origins/regions, or deliver this as a file instead.',
      );
    }
  }
}
