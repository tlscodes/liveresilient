import 'package:clock/clock.dart';
import 'package:security/src/turn_credentials.dart';
import 'package:test/test.dart';

void main() {
  group('TurnCredentialsIssuer.issue known vector', () {
    test('secret "north" + userId "alice" + fixed now match the pinned '
        'coturn use-auth-secret vector', () {
      // Pinned once via an independent Python reference implementation
      // (hmac.new(secret, username, hashlib.sha1) + base64), not derived
      // from this class, so a change in either must be a deliberate,
      // reviewed change to the wire format.
      final fixedNow = DateTime.utc(2026, 7, 16, 0, 0, 0);
      final issuer = TurnCredentialsIssuer(sharedSecret: 'north');

      final creds = withClock(
        Clock.fixed(fixedNow),
        () => issuer.issue('alice'),
      );

      expect(creds.username, '1784163600:alice');
      expect(creds.credential, 'kT+YbrLv/M7+b6yIQZRAeEnc244=');
      expect(creds.expiresAt, DateTime.utc(2026, 7, 16, 1, 0, 0));
    });
  });

  group('TurnCredentialsIssuer.issue ttl math', () {
    test('expiresAt is exactly now + ttl', () {
      final fixedNow = DateTime.utc(2026, 1, 1, 12, 0, 0);
      final issuer = TurnCredentialsIssuer(
        sharedSecret: 's3cret',
        ttl: const Duration(minutes: 30),
      );

      final creds = withClock(Clock.fixed(fixedNow), () => issuer.issue('bob'));

      expect(creds.expiresAt, fixedNow.add(const Duration(minutes: 30)));
      expect(
        creds.username,
        startsWith('${creds.expiresAt.millisecondsSinceEpoch ~/ 1000}:'),
      );
    });

    test('default ttl is one hour', () {
      final issuer = TurnCredentialsIssuer(sharedSecret: 's3cret');
      expect(issuer.ttl, const Duration(hours: 1));
    });

    test('uris are passed through unchanged and not part of the HMAC', () {
      final fixedNow = DateTime.utc(2026, 1, 1);
      final issuer = TurnCredentialsIssuer(sharedSecret: 's3cret');
      const uris = ['turn:host:3478?transport=udp'];

      final withUris = withClock(
        Clock.fixed(fixedNow),
        () => issuer.issue('carol', uris: uris),
      );
      final withoutUris = withClock(
        Clock.fixed(fixedNow),
        () => issuer.issue('carol'),
      );

      expect(withUris.uris, uris);
      expect(withoutUris.uris, isNull);
      expect(withUris.username, withoutUris.username);
      expect(withUris.credential, withoutUris.credential);
    });
  });

  group('TurnCredentialsIssuer.isExpired boundary', () {
    late TurnCredentialsIssuer issuer;
    late TurnCredentials creds;
    late DateTime expiresAt;

    setUp(() {
      issuer = TurnCredentialsIssuer(sharedSecret: 's3cret');
      final fixedNow = DateTime.utc(2026, 1, 1, 0, 0, 0);
      creds = withClock(Clock.fixed(fixedNow), () => issuer.issue('dave'));
      expiresAt = creds.expiresAt;
    });

    test('one second before expiry is not expired', () {
      final now = expiresAt.subtract(const Duration(seconds: 1));
      expect(issuer.isExpired(creds, now: now), isFalse);
    });

    test('exactly at expiry counts as expired (inclusive boundary)', () {
      expect(issuer.isExpired(creds, now: expiresAt), isTrue);
    });

    test('one second after expiry is expired', () {
      final now = expiresAt.add(const Duration(seconds: 1));
      expect(issuer.isExpired(creds, now: now), isTrue);
    });

    test('falls back to the ambient clock when now is omitted', () {
      final result = withClock(
        Clock.fixed(expiresAt.add(const Duration(seconds: 1))),
        () => issuer.isExpired(creds),
      );
      expect(result, isTrue);
    });
  });

  group('TurnCredentialsIssuer distinctness', () {
    test('different userIds under the same secret produce different creds', () {
      final fixedNow = DateTime.utc(2026, 1, 1);
      final issuer = TurnCredentialsIssuer(sharedSecret: 'shared-secret');

      final alice = withClock(
        Clock.fixed(fixedNow),
        () => issuer.issue('alice'),
      );
      final bob = withClock(Clock.fixed(fixedNow), () => issuer.issue('bob'));

      expect(alice.username, isNot(bob.username));
      expect(alice.credential, isNot(bob.credential));
    });

    test('different secrets for the same userId produce different '
        'credentials but the same username', () {
      final fixedNow = DateTime.utc(2026, 1, 1);
      final issuerA = TurnCredentialsIssuer(sharedSecret: 'secret-a');
      final issuerB = TurnCredentialsIssuer(sharedSecret: 'secret-b');

      final credsA = withClock(
        Clock.fixed(fixedNow),
        () => issuerA.issue('alice'),
      );
      final credsB = withClock(
        Clock.fixed(fixedNow),
        () => issuerB.issue('alice'),
      );

      expect(credsA.username, credsB.username);
      expect(credsA.credential, isNot(credsB.credential));
    });
  });

  group('TurnCredentialsIssuer.issue input validation', () {
    test('userId containing a colon throws ArgumentError', () {
      final issuer = TurnCredentialsIssuer(sharedSecret: 's3cret');
      expect(() => issuer.issue('ali:ce'), throwsArgumentError);
    });

    test('empty userId throws ArgumentError', () {
      final issuer = TurnCredentialsIssuer(sharedSecret: 's3cret');
      expect(() => issuer.issue(''), throwsArgumentError);
    });
  });

  group('TurnCredentialsIssuer construction validation', () {
    test('Duration.zero ttl throws ArgumentError at construction', () {
      expect(
        () => TurnCredentialsIssuer(sharedSecret: 's3cret', ttl: Duration.zero),
        throwsArgumentError,
      );
    });

    test('negative ttl throws ArgumentError at construction', () {
      expect(
        () => TurnCredentialsIssuer(
          sharedSecret: 's3cret',
          ttl: const Duration(seconds: -1),
        ),
        throwsArgumentError,
      );
    });

    test('empty sharedSecret throws ArgumentError at construction', () {
      expect(
        () => TurnCredentialsIssuer(sharedSecret: ''),
        throwsArgumentError,
      );
    });
  });
}
