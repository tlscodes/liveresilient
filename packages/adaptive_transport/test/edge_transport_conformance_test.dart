import 'dart:math';
import 'dart:typed_data';

import 'package:adaptive_transport/adaptive_transport.dart';
import 'package:test/test.dart';

void main() {
  group('MicroDatagramLane', () {
    test('restores payload bit-exact across variable length inputs', () {
      final lane = MicroDatagramLane(random: Random(1));
      for (final len in [0, 1, 15, 16, 17, 63, 64, 200]) {
        final payload = Uint8List.fromList(
          List.generate(len, (i) => i % 256),
        );
        final padded = lane.encodeWithPadding(payload);
        expect(padded.length % 16, 0);
        final restored = lane.decodeAndStripPadding(padded);
        expect(restored, equals(payload));
      }
    });

    test('rejects a frame whose padding length exceeds the frame', () {
      final lane = MicroDatagramLane();
      final bogus = Uint8List.fromList([1, 2, 250]);
      expect(() => lane.decodeAndStripPadding(bogus), throwsFormatException);
    });

    test('rejects an empty frame', () {
      final lane = MicroDatagramLane();
      expect(
        () => lane.decodeAndStripPadding(Uint8List(0)),
        throwsFormatException,
      );
    });
  });

  group('TlsParameterNormalizer', () {
    test('emits valid RFC 8701 GREASE values', () {
      final normalizer = TlsParameterNormalizer();
      for (var i = 0; i < 50; i++) {
        final v = normalizer.pickGreaseValue();
        expect(normalizer.isGreaseValue(v), isTrue);
        expect(v & 0x0F0F, 0x0A0A);
      }
    });

    test('cipher suite list leads with a GREASE value then standard suites',
        () {
      final normalizer = TlsParameterNormalizer();
      final suites = normalizer.buildCipherSuites();
      expect(normalizer.isGreaseValue(suites.first), isTrue);
      expect(suites.skip(1), contains(0x1301));
      expect(suites.toSet().length, suites.length);
    });

    test('standard ALPN protocol list matches RFC-registered identifiers',
        () {
      expect(
        TlsParameterNormalizer.standardAlpnProtocols,
        equals(['h2', 'http/1.1']),
      );
    });
  });
}
