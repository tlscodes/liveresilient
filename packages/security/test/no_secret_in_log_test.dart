/// Automated no-secret-in-log gate (blueprint phase 10, exit gate:
/// "automated test that no secret leaks into logs").
///
/// Scope honesty: this test proves the REDACTION LAYER — every realistic
/// secret-bearing line fed through [LogRedactor] / [RedactingLogger] comes
/// out with zero surviving secrets, and the layer fails closed (an internal
/// redaction error drops the whole line rather than passing it through).
/// It does NOT prove that every logger in the real app/server is wired
/// through [RedactingLogger]; that end-to-end assertion needs the running
/// Xcode app (dated device blocker) and, for the signaling server, lands
/// with the signaling_server phase-10 work. This file stays self-contained.
library;

import 'package:security/src/log_redactor.dart';
import 'package:test/test.dart';

class _CorpusLine {
  final String description;
  final String raw;

  /// Secret substrings of [raw] that must have zero occurrences after
  /// redaction.
  final List<String> mustNotSurvive;

  const _CorpusLine(this.description, this.raw, this.mustNotSurvive);
}

/// Realistic log lines, each carrying at least one secret of a category
/// the blueprint forbids in telemetry/logs.
const List<_CorpusLine> _corpus = [
  _CorpusLine(
    'HTTP Authorization header with a short-segment JWT',
    'Authorization: Bearer '
        'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiI0OTMwMTIzNDU2NyJ9.dGVzdHNpZ25hdHVyZQ',
    [
      'eyJhbGciOiJIUzI1NiJ9',
      'eyJzdWIiOiI0OTMwMTIzNDU2NyJ9',
      'dGVzdHNpZ25hdHVyZQ',
    ],
  ),
  _CorpusLine(
    'TURN short-lived credentials (pinned turn_credentials vector format)',
    'turn auth username=1784163600:alice '
        'credential=kT+YbrLv/M7+b6yIQZRAeEnc244= realm=turn.example.org',
    ['1784163600', 'alice', 'kT+YbrLv/M7+b6yIQZRAeEnc244='],
  ),
  _CorpusLine(
    'base64 key material (Ed25519 PKCS#8-ish blob)',
    'loaded session key MFMCAQEwBQYDK2VwBCIEIFJDoUJXtaZfW8A7pW8mLnW5S2v1kQ2H3jZk9fXhYw2v ok',
    ['MFMCAQEwBQYDK2VwBCIEIFJDoUJXtaZfW8A7pW8mLnW5S2v1kQ2H3jZk9fXhYw2v'],
  ),
  _CorpusLine(
    'international phone number',
    'user contact +49 (30) 1234-5678 requested callback',
    ['+49 (30) 1234-5678', '1234-5678'],
  ),
  _CorpusLine('local-format phone number', 'dialing 09123456789 failed', [
    '09123456789',
  ]),
  _CorpusLine(
    'email address',
    'invite sent to alice.tester@example.org (retry 1)',
    ['alice.tester@example.org', 'alice.tester'],
  ),
  _CorpusLine(
    'IPv4 pair in an ICE selection line',
    'ICE pair selected 203.0.113.42:52833 -> relay 198.51.100.7:3478',
    ['203.0.113.42', '198.51.100.7'],
  ),
  _CorpusLine(
    'IPv6 address in a candidate line (free-form log path)',
    'a=candidate:3 1 udp 41885439 2001:db8:85a3::8a2e:370:7334 61665 typ relay',
    ['2001:db8:85a3::8a2e:370:7334'],
  ),
  _CorpusLine(
    'push-token-looking hex blob',
    'push token: '
        '7f0a9c1e4b2d8f6a3c5e7b9d1f0a2c4e6b8d0f1a3c5e7b9d2f4a6c8e0b1d3f5a registered',
    ['7f0a9c1e4b2d8f6a3c5e7b9d1f0a2c4e6b8d0f1a3c5e7b9d2f4a6c8e0b1d3f5a'],
  ),
  _CorpusLine(
    'URL with userinfo credentials and a query-string token',
    'GET https://alice:s3cretPass@relay.example.org/session?access_token=abcDEF123 HTTP/1.1',
    ['s3cretPass', 'abcDEF123'],
  ),
  _CorpusLine(
    'password assignment',
    'login password: hunter2hunter2 accepted',
    ['hunter2hunter2'],
  ),
  _CorpusLine(
    'generic secret assignment',
    'derived secret=deadbeefcafef00ddeadbeefcafef00d for session',
    ['deadbeefcafef00ddeadbeefcafef00d'],
  ),
];

/// A full SDP offer with connection and candidate lines — the blueprint
/// forbids complete SDP in any log.
const String _fullSdp =
    'v=0\r\n'
    'o=- 4611731400430051336 2 IN IP4 198.51.100.7\r\n'
    's=-\r\n'
    'c=IN IP4 198.51.100.7\r\n'
    'a=candidate:1 1 UDP 2130706431 198.51.100.7 54321 typ host\r\n'
    'a=candidate:2 1 UDP 1694498815 203.0.113.9 23456 typ srflx\r\n'
    'a=candidate:3 1 udp 41885439 2001:db8:85a3::8a2e:370:7334 61665 typ relay\r\n'
    'm=audio 54321 UDP/TLS/RTP/SAVPF 111\r\n'
    'a=mid:0\r\n'
    'a=rtpmap:111 opus/48000/2\r\n';

/// Pattern scan applied to every redacted output: shapes of secrets that
/// must never appear, regardless of which corpus line produced them.
final Map<String, RegExp> _secretShapes = {
  'IPv4 address': RegExp(r'(?:\d{1,3}\.){3}\d{1,3}'),
  'IPv6 address': RegExp(r'(?:[0-9a-fA-F]{1,4}:){2,}[0-9a-fA-F]{1,4}'),
  'email address': RegExp(r'[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+'),
  'JWT': RegExp(r'ey[A-Za-z0-9_-]{8,}\.'),
  'long base64/hex blob': RegExp(r'[A-Za-z0-9+/]{24,}'),
  'phone-like digit run': RegExp(r'\+?\d[\d\s()-]{6,}\d'),
};

void _expectNoSecretShapes(String redacted, {required String source}) {
  for (final entry in _secretShapes.entries) {
    expect(
      entry.value.hasMatch(redacted),
      isFalse,
      reason: '${entry.key} shape survived redaction of <$source>: "$redacted"',
    );
  }
}

void main() {
  group('no-secret-in-log gate: LogRedactor.redact over the corpus', () {
    for (final line in _corpus) {
      test('zero secret survival: ${line.description}', () {
        final redacted = LogRedactor.redact(line.raw);
        for (final secret in line.mustNotSurvive) {
          expect(
            redacted.contains(secret),
            isFalse,
            reason: 'secret "$secret" survived: "$redacted"',
          );
        }
        _expectNoSecretShapes(redacted, source: line.description);
      });
    }
  });

  group('no-secret-in-log gate: full SDP blobs', () {
    test('redactSdp leaves no IP, candidate, or connection value', () {
      final redacted = LogRedactor.redactSdp(_fullSdp);

      expect(redacted, isNot(contains('198.51.100.7')));
      expect(redacted, isNot(contains('203.0.113.9')));
      expect(redacted, isNot(contains('2001:db8:85a3::8a2e:370:7334')));
      expect(redacted, isNot(contains('a=candidate')));
      expect(redacted, contains('c=[redacted-connection]'));
      expect(redacted, contains('a=[3 candidate lines redacted]'));
      _expectNoSecretShapes(redacted, source: 'full SDP via redactSdp');
    });

    test('an SDP blob dumped through the free-form path leaks no address', () {
      // Even if someone logs a whole SDP with plain redact() instead of
      // redactSdp(), no address may survive.
      final redacted = LogRedactor.redact(_fullSdp.replaceAll('\r\n', ' '));
      expect(redacted, isNot(contains('198.51.100.7')));
      expect(redacted, isNot(contains('203.0.113.9')));
      expect(redacted, isNot(contains('2001:db8:85a3::8a2e:370:7334')));
      _expectNoSecretShapes(redacted, source: 'full SDP via redact');
    });
  });

  group('no-secret-in-log gate: RedactingLogger end-to-end', () {
    test('every sink line is redacted at every level', () {
      final captured = <String>[];
      final logger = RedactingLogger(
        (level, message) => captured.add(message),
        minimumLevel: LogLevel.debug,
      );

      for (final line in _corpus) {
        logger.debug(line.raw);
        logger.info(line.raw);
        logger.warning(line.raw);
        logger.error(line.raw);
      }

      expect(captured, hasLength(_corpus.length * 4));
      for (final message in captured) {
        for (final line in _corpus) {
          for (final secret in line.mustNotSurvive) {
            expect(
              message.contains(secret),
              isFalse,
              reason: 'secret "$secret" reached the sink: "$message"',
            );
          }
        }
        _expectNoSecretShapes(message, source: 'RedactingLogger sink');
      }
    });
  });

  group('no-secret-in-log gate: fails closed', () {
    tearDown(() {
      LogRedactor.debugSimulateInternalError = false;
    });

    test('an internal redaction error drops the entire line', () {
      LogRedactor.debugSimulateInternalError = true;

      final redacted = LogRedactor.redact(
        'secret=kT+YbrLv/M7+b6yIQZRAeEnc244=',
      );

      expect(redacted, '[redaction-failure: line dropped]');
      expect(redacted, isNot(contains('kT+YbrLv')));
    });

    test('RedactingLogger inherits the fail-closed behavior', () {
      LogRedactor.debugSimulateInternalError = true;
      final captured = <String>[];
      final logger = RedactingLogger((level, message) => captured.add(message));

      logger.error('bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ4In0.c2ln');

      expect(captured.single, '[redaction-failure: line dropped]');
    });
  });
}
