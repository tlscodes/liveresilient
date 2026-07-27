import 'dart:math';
import 'dart:typed_data';

// The package exports its own circuit-breaker Clock; this test needs the
// clock-package one for withClock time travel.
import 'package:adaptive_transport/adaptive_transport.dart' hide Clock;
import 'package:clock/clock.dart';
import 'package:test/test.dart';

const _keyId = 'relay-key-1';
final Uint8List _secret = Uint8List.fromList(
  List<int>.generate(32, (i) => i * 7 + 1),
);

AuthenticatedRelayServer _server({
  Duration lifetime = const Duration(seconds: 30),
}) => AuthenticatedRelayServer(
  sharedKeys: {_keyId: _secret},
  nonceLifetime: lifetime,
);

/// Builds a credential whose MAC is correct for [server].
SessionCredential _signed(
  AuthenticatedRelayServer server, {
  String keyId = _keyId,
  required String nonce,
  required int issuedAtMs,
  String sni = 'relay.example.org',
}) {
  final unsigned = SessionCredential(
    keyId: keyId,
    nonce: nonce,
    issuedAtMs: issuedAtMs,
    mac: Uint8List(0),
    sniHostName: sni,
  );
  return SessionCredential(
    keyId: keyId,
    nonce: nonce,
    issuedAtMs: issuedAtMs,
    mac: server.expectedMac(unsigned),
    sniHostName: sni,
  );
}

void main() {
  group('AuthenticatedRelayServer', () {
    final at = DateTime.utc(2026, 7, 26, 12);

    test('a valid nonce establishes a session', () {
      withClock(Clock.fixed(at), () {
        final server = _server();
        final outcome = server.handleHandshake(
          _signed(server, nonce: 'n-1', issuedAtMs: at.millisecondsSinceEpoch),
        );
        expect(outcome.accepted, isTrue);
        expect(outcome.statusCode, 200);
        expect(outcome.closeConnection, isFalse);
        expect(outcome.sessionId, isNotNull);
        expect(outcome.wwwAuthenticate, isNull);
      });
    });

    test('an unknown key id gets HTTP 401 with a challenge and is closed', () {
      withClock(Clock.fixed(at), () {
        final server = _server();
        final outcome = server.handleHandshake(
          SessionCredential(
            keyId: 'not-provisioned',
            nonce: 'n-2',
            issuedAtMs: at.millisecondsSinceEpoch,
            mac: Uint8List(32),
          ),
        );
        expect(outcome.statusCode, 401);
        expect(outcome.rejection, HandshakeRejection.unknownKeyId);
        expect(outcome.closeConnection, isTrue);
        expect(outcome.sessionId, isNull);
        // RFC 9110 section 11.6.1: a 401 must carry at least one challenge.
        expect(outcome.wwwAuthenticate, 'HMAC-SHA256 realm="relay"');
      });
    });

    test('a forged MAC gets HTTP 401 and is closed', () {
      withClock(Clock.fixed(at), () {
        final server = _server();
        final good = _signed(
          server,
          nonce: 'n-3',
          issuedAtMs: at.millisecondsSinceEpoch,
        );
        final tampered = Uint8List.fromList(good.mac)..[0] ^= 0xFF;
        final outcome = server.handleHandshake(
          SessionCredential(
            keyId: good.keyId,
            nonce: good.nonce,
            issuedAtMs: good.issuedAtMs,
            mac: tampered,
            sniHostName: good.sniHostName,
          ),
        );
        expect(outcome.statusCode, 401);
        expect(outcome.rejection, HandshakeRejection.badMac);
        expect(outcome.closeConnection, isTrue);
      });
    });

    test('a MAC minted for one SNI host does not authorize another', () {
      withClock(Clock.fixed(at), () {
        final server = _server();
        final forHostA = _signed(
          server,
          nonce: 'n-4',
          issuedAtMs: at.millisecondsSinceEpoch,
          sni: 'a.example.org',
        );
        final movedToHostB = SessionCredential(
          keyId: forHostA.keyId,
          nonce: forHostA.nonce,
          issuedAtMs: forHostA.issuedAtMs,
          mac: forHostA.mac,
          sniHostName: 'b.example.org',
        );
        expect(
          server.handleHandshake(movedToHostB).rejection,
          HandshakeRejection.badMac,
        );
      });
    });

    test('replaying an accepted nonce is refused with 401', () {
      withClock(Clock.fixed(at), () {
        final server = _server();
        final credential = _signed(
          server,
          nonce: 'n-5',
          issuedAtMs: at.millisecondsSinceEpoch,
        );
        expect(server.handleHandshake(credential).accepted, isTrue);
        final replay = server.handleHandshake(credential);
        expect(replay.statusCode, 401);
        expect(replay.rejection, HandshakeRejection.replayedNonce);
        expect(replay.closeConnection, isTrue);
      });
    });

    test('a stale or future-dated credential is refused with 401', () {
      final server = _server(lifetime: const Duration(seconds: 10));
      final stale = withClock(
        Clock.fixed(at),
        () => _signed(
          server,
          nonce: 'n-6',
          issuedAtMs: at.millisecondsSinceEpoch,
        ),
      );
      withClock(Clock.fixed(at.add(const Duration(seconds: 11))), () {
        final outcome = server.handleHandshake(stale);
        expect(outcome.statusCode, 401);
        expect(outcome.rejection, HandshakeRejection.expired);
      });
      withClock(Clock.fixed(at.subtract(const Duration(seconds: 5))), () {
        expect(
          server.handleHandshake(stale).rejection,
          HandshakeRejection.expired,
        );
      });
    });

    test('spent nonces are pruned once they can no longer be replayed', () {
      final server = _server(lifetime: const Duration(seconds: 10));
      withClock(Clock.fixed(at), () {
        expect(
          server
              .handleHandshake(
                _signed(
                  server,
                  nonce: 'n-7',
                  issuedAtMs: at.millisecondsSinceEpoch,
                ),
              )
              .accepted,
          isTrue,
        );
        expect(server.trackedNonceCount, 1);
      });
      final later = at.add(const Duration(seconds: 25));
      withClock(Clock.fixed(later), () {
        expect(
          server
              .handleHandshake(
                _signed(
                  server,
                  nonce: 'n-8',
                  issuedAtMs: later.millisecondsSinceEpoch,
                ),
              )
              .accepted,
          isTrue,
        );
        // The 10s-lifetime nonce from 25s ago is gone; only the fresh one is held.
        expect(server.trackedNonceCount, 1);
      });
    });

    test('an empty key id or nonce is malformed, not a MAC failure', () {
      withClock(Clock.fixed(at), () {
        final server = _server();
        expect(
          server
              .handleHandshake(
                SessionCredential(
                  keyId: '',
                  nonce: 'n-9',
                  issuedAtMs: at.millisecondsSinceEpoch,
                  mac: Uint8List(32),
                ),
              )
              .rejection,
          HandshakeRejection.malformed,
        );
        expect(
          server
              .handleHandshake(
                SessionCredential(
                  keyId: _keyId,
                  nonce: '',
                  issuedAtMs: at.millisecondsSinceEpoch,
                  mac: Uint8List(32),
                ),
              )
              .rejection,
          HandshakeRejection.malformed,
        );
      });
    });
  });

  group('MultiHomedConnector', () {
    final endpoints = [
      RelayEndpoint(
        hostPort: const HostPort(host: '198.51.100.10', port: 443),
        sniHostName: 'a.relay.example.org',
      ),
      RelayEndpoint(
        hostPort: const HostPort(host: '198.51.100.11', port: 443),
        sniHostName: 'b.relay.example.org',
      ),
      RelayEndpoint(hostPort: const HostPort(host: '198.51.100.12', port: 443)),
    ];

    test('defaults the SNI host name to the endpoint host', () {
      expect(endpoints[2].sniHostName, '198.51.100.12');
      expect(
        () => RelayEndpoint(
          hostPort: const HostPort(host: 'h', port: 1),
          sniHostName: '  ',
        ),
        throwsArgumentError,
      );
    });

    test('switches to the next endpoint when the current one fails', () async {
      final tried = <String>[];
      final connector = MultiHomedConnector<String>(
        endpoints: endpoints,
        random: Random(3),
        sleep: (_) async {},
        connect: (endpoint) async {
          tried.add(endpoint.sniHostName);
          if (endpoint.sniHostName != 'b.relay.example.org') {
            throw StateError('path down: ${endpoint.hostPort.authority}');
          }
          return 'session-on-${endpoint.hostPort.authority}';
        },
      );

      expect(await connector.connect(), 'session-on-198.51.100.11:443');
      expect(tried, ['a.relay.example.org', 'b.relay.example.org']);
      // The working endpoint stays first for the next attempt.
      expect(connector.currentEndpoint.sniHostName, 'b.relay.example.org');
    });

    test('a degraded live path moves the cursor on for the next connect', () {
      final connector = MultiHomedConnector<String>(
        endpoints: endpoints,
        sleep: (_) async {},
        connect: (_) async => 'ok',
      );
      expect(connector.currentEndpoint.sniHostName, 'a.relay.example.org');
      connector.reportPathDegraded();
      expect(connector.currentEndpoint.sniHostName, 'b.relay.example.org');
      expect(connector.rotation.map((e) => e.hostPort.host), [
        '198.51.100.11',
        '198.51.100.12',
        '198.51.100.10',
      ]);
    });

    test('throws once every endpoint has been exhausted', () async {
      int calls = 0;
      final connector = MultiHomedConnector<String>(
        endpoints: endpoints,
        attemptsPerEndpoint: 2,
        sleep: (_) async {},
        connect: (_) async {
          calls++;
          throw StateError('all paths down');
        },
      );
      await expectLater(
        connector.connect(),
        throwsA(isA<NoReachableEndpointException>()),
      );
      expect(calls, endpoints.length * 2);
    });

    test('backoff ceiling doubles per retry and clamps to maxBackoff', () {
      final connector = MultiHomedConnector<String>(
        endpoints: endpoints,
        baseBackoff: const Duration(milliseconds: 100),
        maxBackoff: const Duration(milliseconds: 800),
        sleep: (_) async {},
        connect: (_) async => 'ok',
      );
      expect(connector.backoffCeilingFor(0), Duration.zero);
      expect(connector.backoffCeilingFor(1), const Duration(milliseconds: 200));
      expect(connector.backoffCeilingFor(2), const Duration(milliseconds: 400));
      expect(connector.backoffCeilingFor(3), const Duration(milliseconds: 800));
      expect(connector.backoffCeilingFor(9), const Duration(milliseconds: 800));
      expect(
        connector.backoffCeilingFor(99),
        const Duration(milliseconds: 800),
      );
    });

    test('every retry waits inside the jittered backoff window', () async {
      final waits = <Duration>[];
      final connector = MultiHomedConnector<String>(
        endpoints: endpoints,
        baseBackoff: const Duration(milliseconds: 100),
        maxBackoff: const Duration(seconds: 1),
        random: Random(11),
        sleep: (d) async => waits.add(d),
        connect: (endpoint) async {
          if (endpoint.hostPort.host != '198.51.100.12') {
            throw StateError('down');
          }
          return 'ok';
        },
      );

      expect(await connector.connect(), 'ok');
      expect(waits.length, 2); // No wait before the first attempt.
      for (int i = 0; i < waits.length; i++) {
        final ceiling = connector.backoffCeilingFor(i + 1);
        expect(waits[i], greaterThanOrEqualTo(Duration.zero));
        expect(waits[i], lessThanOrEqualTo(ceiling));
      }
    });

    test('rejects an empty endpoint list and impossible bounds', () {
      expect(
        () => MultiHomedConnector<String>(
          endpoints: const [],
          connect: (_) async => 'ok',
        ),
        throwsArgumentError,
      );
      expect(
        () => MultiHomedConnector<String>(
          endpoints: endpoints,
          attemptsPerEndpoint: 0,
          connect: (_) async => 'ok',
        ),
        throwsArgumentError,
      );
      expect(
        () => MultiHomedConnector<String>(
          endpoints: endpoints,
          baseBackoff: const Duration(seconds: 5),
          maxBackoff: const Duration(seconds: 1),
          connect: (_) async => 'ok',
        ),
        throwsArgumentError,
      );
    });
  });
}
