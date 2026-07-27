import 'dart:math';
import 'dart:typed_data';

import 'package:adaptive_transport/adaptive_transport.dart';
import 'package:test/test.dart';

/// A deterministic RNG so a built hello is reproducible byte-for-byte.
Random _seeded([int seed = 7]) => Random(seed);

Uint8List _build(
  UtlsClientProfile profile, {
  String? serverName = 'www.example.com',
  bool enableEch = false,
  int seed = 7,
  int? padToLength,
}) {
  final builder =
      UtlsClientHelloBuilder(profile: profile, random: _seeded(seed));
  return builder.build(
    serverName: serverName,
    enableEch: enableEch,
    padToLength: padToLength,
  );
}

void main() {
  group('TlsClientHello parsing', () {
    test('round-trips every profile the builder can emit', () {
      for (final profile in UtlsClientProfile.all) {
        final hello = TlsClientHello.parseHandshake(_build(profile));
        expect(hello.legacyVersion, 0x0303, reason: profile.id.name);
        expect(hello.random, hasLength(32));
        expect(hello.sessionId, hasLength(32));
        expect(hello.compressionMethods, [0x00]);
        expect(hello.serverName, 'www.example.com');
        expect(hello.alpnProtocols, ['h2', 'http/1.1']);
        expect(hello.effectiveVersion, 0x0304);
      }
    });

    test('parses a hello wrapped in a record header', () {
      final record =
          UtlsClientHelloBuilder.wrapInRecord(_build(UtlsClientProfile.chrome120));
      final hello = TlsClientHello.parseRecord(record);
      expect(hello.serverName, 'www.example.com');
    });

    test('rejects a truncated record rather than deciding on half a hello',
        () {
      final record =
          UtlsClientHelloBuilder.wrapInRecord(_build(UtlsClientProfile.chrome120));
      final half = Uint8List.sublistView(record, 0, record.length ~/ 2);
      expect(
        () => TlsClientHello.parseRecord(half),
        throwsA(isA<TlsParseException>()),
      );
    });

    test('rejects a non-handshake content type', () {
      expect(
        () => TlsClientHello.parseRecord(
          Uint8List.fromList([0x17, 0x03, 0x03, 0x00, 0x01, 0x00]),
        ),
        throwsA(isA<TlsParseException>()),
      );
    });

    test('rejects a hello whose extensions block ends mid-extension', () {
      final good = _build(UtlsClientProfile.firefox120);
      // Chop two bytes off the end and fix the outer length so only the
      // inner extensions vector is inconsistent.
      final body = good.sublist(4, good.length - 2);
      final broken = BytesBuilder(copy: false)
        ..addByte(0x01)
        ..add([
          (body.length >> 16) & 0xFF,
          (body.length >> 8) & 0xFF,
          body.length & 0xFF,
        ])
        ..add(body);
      expect(
        () => TlsClientHello.parseHandshake(broken.toBytes()),
        throwsA(isA<TlsParseException>()),
      );
    });

    test('reads no server name when SNI is absent (the ECH inner case)', () {
      final hello = TlsClientHello.parseHandshake(
        _build(UtlsClientProfile.chrome120, serverName: null),
      );
      expect(hello.serverName, isNull);
      expect(hello.extension(TlsExtensionType.serverName), isNull);
    });

    test('preserves extension order exactly as received', () {
      final profile = UtlsClientProfile.firefox120; // does not shuffle
      final hello = TlsClientHello.parseHandshake(_build(profile));
      final seen = hello.extensions
          .map((e) => e.type)
          .where((t) => !isGreaseCodePoint(t))
          .toList();
      final expected = profile.extensionOrder
          .where((t) => t != TlsExtensionType.recordSizeLimit ||
              profile.recordSizeLimit != null)
          .toList();
      expect(seen, expected);
    });
  });

  group('JA3', () {
    test('excludes GREASE from every field', () {
      final hello = TlsClientHello.parseHandshake(_build(UtlsClientProfile.chrome120));
      final fields = hello.ja3String.split(',');
      expect(fields, hasLength(5));
      for (final value in fields.skip(1).expand((f) => f.split('-'))) {
        if (value.isEmpty) continue;
        expect(isGreaseCodePoint(int.parse(value)), isFalse,
            reason: 'GREASE value $value leaked into JA3');
      }
    });

    test('is a 32-character MD5 hex digest', () {
      final hello = TlsClientHello.parseHandshake(_build(UtlsClientProfile.safari17));
      expect(hello.ja3, matches(RegExp(r'^[0-9a-f]{32}$')));
    });

    test('differs between browser profiles', () {
      final digests = {
        for (final profile in UtlsClientProfile.all)
          profile.id: TlsClientHello.parseHandshake(_build(profile)).ja3,
      };
      expect(digests.values.toSet(), hasLength(UtlsClientProfile.all.length));
    });

    test('a shuffled Chrome hello changes JA3 — which is why JA3 alone is '
        'not a stable identity for Chrome', () {
      final a = TlsClientHello.parseHandshake(
        _build(UtlsClientProfile.chrome120, seed: 1),
      );
      final b = TlsClientHello.parseHandshake(
        _build(UtlsClientProfile.chrome120, seed: 2),
      );
      expect(a.ja3, isNot(b.ja3));
    });
  });

  group('JA4', () {
    test('has the documented three-part shape', () {
      final hello = TlsClientHello.parseHandshake(_build(UtlsClientProfile.chrome120));
      expect(
        hello.ja4(),
        matches(RegExp(r'^t13d\d{4}h2_[0-9a-f]{12}_[0-9a-f]{12}$')),
      );
    });

    test('marks a hello without SNI with "i" instead of "d"', () {
      final hello = TlsClientHello.parseHandshake(
        _build(UtlsClientProfile.chrome120, serverName: null),
      );
      expect(hello.ja4().startsWith('t13i'), isTrue);
    });

    test('uses "q" for a QUIC-carried hello', () {
      final hello = TlsClientHello.parseHandshake(_build(UtlsClientProfile.chrome120));
      expect(hello.ja4(overQuic: true).startsWith('q13'), isTrue);
    });

    test('is stable across Chrome extension shuffling, unlike JA3', () {
      final digests = <String>{};
      for (var seed = 1; seed <= 8; seed++) {
        digests.add(
          TlsClientHello.parseHandshake(
            _build(UtlsClientProfile.chrome120, seed: seed),
          ).ja4(),
        );
      }
      expect(digests, hasLength(1),
          reason: 'JA4 sorts its lists, so order permutation must not move it');
    });

    test('counts exclude GREASE', () {
      final hello = TlsClientHello.parseHandshake(_build(UtlsClientProfile.chrome120));
      final a = hello.ja4().split('_').first;
      final cipherCount = int.parse(a.substring(4, 6));
      expect(cipherCount, UtlsClientProfile.chrome120.cipherSuites.length);
    });

    test('differs between browser profiles', () {
      final digests = {
        for (final profile in UtlsClientProfile.all)
          profile.id: TlsClientHello.parseHandshake(_build(profile)).ja4(),
      };
      expect(digests.values.toSet(), hasLength(UtlsClientProfile.all.length));
    });
  });
}
