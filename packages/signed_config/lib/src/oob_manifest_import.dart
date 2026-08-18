/// Getting the first address without the network that address is for.
///
/// THE CIRCULARITY THIS BREAKS. Every ingress for an endpoint manifest today is
/// `ManifestFetcher(Uri)` over HTTPS. So the list of addresses can only be
/// obtained from the network the list exists to reach. An existing install is
/// saved by its cache; a FRESH install on a blocked network has nothing at all,
/// and a fresh install is precisely the case that matters — no amount of
/// transport cleverness downstream can rescue a client that cannot learn where
/// to connect.
///
/// THE FIX IS AN INGRESS, NOT A TRUST DECISION. `ManifestVerifier.verify`
/// already takes a parsed document and checks pinned keys, validity window and
/// revision monotonicity. Nothing about those rules depends on how the bytes
/// arrived. This file adds ways for the bytes to arrive — a file, a pasted
/// string, a scanned code — and then hands them to the exact same verifier with
/// the exact same `lastAcceptedRevision`.
///
/// **An out-of-band manifest is not more trusted. It is differently
/// delivered.** A tampered code fails signature verification and is rejected;
/// it does not become a manifest full of hostile endpoints. That property is
/// what makes it safe to accept a manifest from a photograph, a printout, or a
/// string read aloud over a phone call.
///
/// Precedent deliberately reused rather than reinvented: `BootstrapCode` in
/// `packages/broadcast` already carries a relay and a key in Crockford base32
/// "to be photographed, printed, or read over a phone call". The alphabet here
/// is identical so the two artifacts look and behave like relatives.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'endpoint_manifest.dart';
import 'manifest_verifier.dart';

/// Where an out-of-band manifest came from. Recorded and shown to the user,
/// because "which endpoints am I trusting, and who handed them to me" is a
/// question a person should be able to answer.
enum OobManifestSource {
  /// A file the user chose (sideloaded, AirDropped, on a USB stick).
  file,

  /// Text pasted or typed by the user.
  pastedText,

  /// A scanned or photographed code.
  scannedCode,

  /// Shipped inside the app build as a last-resort seed.
  bundledSeed,
}

/// Why a compact code could not be turned back into bytes.
enum CompactDecodeError {
  /// Not this format at all (wrong prefix or no recognizable payload).
  notACode,

  /// A character outside the alphabet survived normalization.
  badCharacter,

  /// Correctly shaped, but the checksum says at least one symbol is wrong —
  /// a mistyped or misread character, caught before it can become a
  /// different, valid-looking document.
  checksumMismatch,

  /// A version this build does not implement.
  unsupportedVersion,

  /// Longer than [CompactManifestCode.maxPayloadBytes].
  tooLarge,
}

class CompactDecodeException implements Exception {
  const CompactDecodeException(this.error, this.detail);
  final CompactDecodeError error;
  final String detail;

  @override
  String toString() => 'CompactDecodeException(${error.name}: $detail)';
}

/// A signed manifest document encoded so a human can move it.
///
/// Format: `CFM1-` prefix, then Crockford base32 over
/// `[version byte] [payload bytes] [CRC-16/CCITT-FALSE, big endian]`,
/// grouped in blocks of five characters with hyphens for readability.
/// Hyphens, whitespace and case are all ignored when decoding.
///
/// SIZE, STATED HONESTLY. Base32 costs 8 characters per 5 bytes, so a 1 KB
/// signed document becomes ~1,650 characters. That fits a QR code in
/// alphanumeric mode with room to spare, and does not fit on a business card.
/// There is deliberately no compression: pure Dart has no gzip in its core
/// libraries, and adding a dependency to a bootstrap artifact — the one thing
/// that must work when everything else is unavailable — buys a smaller code at
/// the cost of another way to fail. A deployment that needs a shorter code
/// should sign a SMALLER manifest (fewer origins, fewer regions), which is an
/// operations choice, not an encoding problem.
class CompactManifestCode {
  const CompactManifestCode._();

  /// Marks the artifact so a scanner can tell it from a `BootstrapCode` or a
  /// URL before trying to decode it.
  static const String prefix = 'CFM1-';

  /// The only version this build writes or reads.
  static const int version = 1;

  /// Crockford's alphabet: no I, L, O or U, so nothing can be confused with a
  /// digit or with another letter by a reader, a listener, or an OCR pass.
  static const String alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

  /// Upper bound on the document a code may carry. Past this the honest answer
  /// is a file, not a longer code that nobody can scan reliably.
  static const int maxPayloadBytes = 4096;

  /// Characters per hyphen-separated group.
  static const int groupSize = 5;

  static String encode(List<int> documentBytes) {
    if (documentBytes.length > maxPayloadBytes) {
      throw const CompactDecodeException(
        CompactDecodeError.tooLarge,
        'document exceeds maxPayloadBytes',
      );
    }
    final framed = Uint8List(1 + documentBytes.length + 2);
    framed[0] = version;
    framed.setRange(1, 1 + documentBytes.length, documentBytes);
    final crc = _crc16(framed.sublist(0, 1 + documentBytes.length));
    framed[framed.length - 2] = (crc >> 8) & 0xFF;
    framed[framed.length - 1] = crc & 0xFF;

    final symbols = _toBase32(framed);
    final grouped = StringBuffer(prefix);
    for (var i = 0; i < symbols.length; i += groupSize) {
      if (i > 0) grouped.write('-');
      grouped.write(
        symbols.substring(
          i,
          i + groupSize > symbols.length ? symbols.length : i + groupSize,
        ),
      );
    }
    return grouped.toString();
  }

  /// Recovers the document bytes, or throws [CompactDecodeException].
  ///
  /// Normalization is deliberately generous, because the input was typed by a
  /// person or read by a camera: case is folded, hyphens and whitespace are
  /// dropped, and the letters people actually substitute are mapped back
  /// (O to 0, I and L to 1) exactly as Crockford specifies. Generosity stops at
  /// the checksum — a code that normalizes cleanly but fails CRC is rejected,
  /// never guessed at.
  static Uint8List decode(String code) {
    // The prefix is matched on a SEPARATOR-FREE view of the code, but the
    // payload is taken from the original text.
    //
    // Both halves matter. A form that reformats a code, or a person reading it
    // aloud, turns "CFM1-ABCD" into "CFM1 ABCD", so a literal prefix match
    // would reject a perfectly readable code. But stripping separators first
    // and then cutting `prefix.length` characters removes one character too
    // few — the hyphen is part of the prefix — and the payload silently starts
    // one symbol late, which surfaces as a CRC failure rather than as a format
    // error. So: find where the prefix ends by counting real characters.
    final text0 = code.trim();
    final upper = text0.toUpperCase();
    final bare = prefix.replaceAll(RegExp(r'[-\s]'), ''); // 'CFM1' from 'CFM1-'

    var seen = 0;
    var cut = -1;
    for (var i = 0; i < upper.length; i++) {
      final ch = upper[i];
      if (ch == '-' || ch == ' ' || ch == '\n' || ch == '\r' || ch == '\t') {
        // A separator inside or right after the prefix is skipped, not counted.
        if (seen > 0 && seen <= bare.length) continue;
        break;
      }
      if (seen < bare.length && ch == bare[seen]) {
        seen++;
        if (seen == bare.length) {
          cut = i + 1;
          // Consume one separator immediately after the prefix, if present.
          if (cut < text0.length &&
              RegExp(r'[-\s]').hasMatch(text0[cut])) {
            cut++;
          }
          break;
        }
        continue;
      }
      break;
    }

    if (cut < 0) {
      throw const CompactDecodeException(
        CompactDecodeError.notACode,
        'missing $prefix prefix',
      );
    }
    var text = text0.substring(cut);

    final buffer = StringBuffer();
    for (final rune in text.toUpperCase().runes) {
      final ch = String.fromCharCode(rune);
      if (ch == '-' || ch == ' ' || ch == '\n' || ch == '\r' || ch == '\t') {
        continue;
      }
      final normalized = switch (ch) {
        'O' => '0',
        'I' || 'L' => '1',
        _ => ch,
      };
      if (!alphabet.contains(normalized)) {
        throw CompactDecodeException(
          CompactDecodeError.badCharacter,
          'character "$ch" is not in the alphabet',
        );
      }
      buffer.write(normalized);
    }

    final framed = _fromBase32(buffer.toString());
    if (framed.length < 4) {
      throw const CompactDecodeException(
        CompactDecodeError.notACode,
        'too short to contain version, payload and checksum',
      );
    }
    if (framed[0] != version) {
      throw CompactDecodeException(
        CompactDecodeError.unsupportedVersion,
        'code version ${framed[0]}, this build reads $version',
      );
    }
    final body = framed.sublist(0, framed.length - 2);
    final expected = (framed[framed.length - 2] << 8) | framed[framed.length - 1];
    if (_crc16(body) != expected) {
      throw const CompactDecodeException(
        CompactDecodeError.checksumMismatch,
        'checksum does not match: at least one symbol is wrong',
      );
    }
    return Uint8List.fromList(body.sublist(1));
  }

  static String _toBase32(Uint8List data) {
    final out = StringBuffer();
    var buffer = 0;
    var bits = 0;
    for (final byte in data) {
      buffer = (buffer << 8) | byte;
      bits += 8;
      while (bits >= 5) {
        out.write(alphabet[(buffer >> (bits - 5)) & 0x1F]);
        bits -= 5;
      }
    }
    if (bits > 0) {
      out.write(alphabet[(buffer << (5 - bits)) & 0x1F]);
    }
    return out.toString();
  }

  static Uint8List _fromBase32(String symbols) {
    final out = <int>[];
    var buffer = 0;
    var bits = 0;
    for (final rune in symbols.runes) {
      final value = alphabet.indexOf(String.fromCharCode(rune));
      buffer = (buffer << 5) | value;
      bits += 5;
      if (bits >= 8) {
        out.add((buffer >> (bits - 8)) & 0xFF);
        bits -= 8;
      }
    }
    return Uint8List.fromList(out);
  }

  /// CRC-16/CCITT-FALSE. Chosen over a single Crockford check symbol because a
  /// scanned code can lose or duplicate several characters at once, and one
  /// check symbol only reliably catches a single-character error.
  static int _crc16(List<int> data) {
    var crc = 0xFFFF;
    for (final byte in data) {
      crc ^= byte << 8;
      for (var i = 0; i < 8; i++) {
        crc = (crc & 0x8000) != 0 ? ((crc << 1) ^ 0x1021) : (crc << 1);
        crc &= 0xFFFF;
      }
    }
    return crc;
  }
}

/// The outcome of importing a manifest out of band.
final class OobImportResult {
  const OobImportResult({
    required this.source,
    required this.verification,
    this.decodeError,
  });

  final OobManifestSource source;

  /// The verifier's verdict — the SAME type the network path produces, because
  /// it is the same verifier with the same rules.
  final ManifestVerification? verification;

  /// Set when the bytes never reached the verifier: not a code, bad checksum,
  /// malformed JSON. Distinct from a verification rejection, because the two
  /// call for opposite recoveries — "read the code again" versus "distrust
  /// whoever gave it to you".
  final CompactDecodeException? decodeError;

  bool get accepted => verification is ManifestAccepted;

  EndpointManifest? get manifest =>
      verification is ManifestAccepted
          ? (verification! as ManifestAccepted).manifest
          : null;

  /// A line safe to show a user or write to a log: never key material, never
  /// the document itself.
  String describe() {
    if (decodeError != null) {
      return 'could not read the ${source.name}: ${decodeError!.error.name}';
    }
    final v = verification;
    return switch (v) {
      ManifestAccepted(:final manifest) =>
        'accepted revision ${manifest.revision} from ${source.name}, '
            '${manifest.iceServers.length} ICE servers',
      ManifestRejected(:final reason) =>
        'rejected from ${source.name}: ${reason.name}',
      _ => 'nothing to import from ${source.name}',
    };
  }
}

/// Imports a signed manifest that arrived by any means other than the network.
///
/// Deliberately free of `dart:io`: the caller reads the file, opens the camera,
/// or reads the clipboard, and hands over bytes or a string. That keeps this
/// class testable with no platform and makes the trust boundary obvious — the
/// only thing that decides whether a manifest is acceptable is the verifier.
class OobManifestImport {
  OobManifestImport({
    required ManifestVerifier verifier,
    required int Function() lastAcceptedRevision,
  }) : _verifier = verifier,
       _lastAcceptedRevision = lastAcceptedRevision;

  final ManifestVerifier _verifier;

  /// Read from the manifest cache at import time, never captured once: an
  /// import that raced a network refresh must still be judged against the
  /// newest revision the device has accepted, or rollback protection has a
  /// hole in exactly the situation an attacker would choose.
  final int Function() _lastAcceptedRevision;

  /// Imports raw signed-document bytes (the `{"manifest":…,"signature":…}`
  /// JSON form) — what a sideloaded file contains.
  Future<OobImportResult> importBytes(
    List<int> bytes, {
    OobManifestSource source = OobManifestSource.file,
    DateTime? now,
  }) async {
    final SignedManifestDocument document;
    try {
      document = SignedManifestDocument.fromBytes(bytes);
    } on FormatException catch (e) {
      return OobImportResult(
        source: source,
        verification: ManifestRejected(
          ManifestRejection.malformed,
          'out-of-band document did not parse: ${e.message}',
        ),
      );
    }
    final verification = await _verifier.verify(
      document,
      lastAcceptedRevision: _lastAcceptedRevision(),
      now: now,
    );
    return OobImportResult(source: source, verification: verification);
  }

  /// Imports a compact code (scanned, typed, or read aloud).
  Future<OobImportResult> importCode(
    String code, {
    OobManifestSource source = OobManifestSource.scannedCode,
    DateTime? now,
  }) async {
    final Uint8List documentBytes;
    try {
      documentBytes = CompactManifestCode.decode(code);
    } on CompactDecodeException catch (e) {
      return OobImportResult(source: source, verification: null, decodeError: e);
    }
    return importBytes(documentBytes, source: source, now: now);
  }

  /// Imports pasted text, accepting either form: a compact code or the raw
  /// signed JSON. A person pasting something should not have to know which.
  Future<OobImportResult> importText(String text, {DateTime? now}) {
    final trimmed = text.trim();
    if (trimmed.toUpperCase().contains(CompactManifestCode.prefix)) {
      return importCode(
        trimmed,
        source: OobManifestSource.pastedText,
        now: now,
      );
    }
    return importBytes(
      utf8.encode(trimmed),
      source: OobManifestSource.pastedText,
      now: now,
    );
  }
}
