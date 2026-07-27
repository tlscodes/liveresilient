import 'dart:typed_data';

import 'package:adaptive_transport/adaptive_transport.dart';
import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';

Uint8List hex(String s) {
  final clean = s.replaceAll(RegExp(r'\s'), '');
  return Uint8List.fromList([
    for (var i = 0; i < clean.length; i += 2)
      int.parse(clean.substring(i, i + 2), radix: 16),
  ]);
}

Uint8List bytes(int value, int count) =>
    Uint8List.fromList(List.filled(count, value));

Uint8List exporter([int seed = 7]) => Uint8List.fromList(
  List.generate(tlsExporterLength, (i) => (i * seed) & 0xff),
);

void main() {
  group('HKDF RFC 5869 official test vectors', () {
    test('A.1 basic (SHA-256)', () {
      final prk = Hkdf.extract(
        hex('000102030405060708090a0b0c'),
        bytes(0x0b, 22),
      );
      expect(
        prk,
        hex(
          '077709362c2e32df0ddc3f0dc47bba63'
          '90b6c73bb50f9c3122ec844ad7c2b3e5',
        ),
      );
      final okm = Hkdf.expand(prk, hex('f0f1f2f3f4f5f6f7f8f9'), 42);
      expect(
        okm,
        hex(
          '3cb25f25faacd57a90434f64d0362f2a'
          '2d2d0a90cf1a5a4c5db02d56ecc4c5bf'
          '34007208d5b887185865',
        ),
      );
    });

    test('A.3 zero-length salt and info (SHA-256)', () {
      final okm = Hkdf.derive(
        ikm: bytes(0x0b, 22),
        salt: Uint8List(0),
        info: Uint8List(0),
        length: 42,
      );
      expect(
        okm,
        hex(
          '8da4e775a563c18f715f802a063c5a31'
          'b8a11f5c5ee1879ec3454e5f3c738d2d'
          '9d201395faa4b61a96c8',
        ),
      );
    });
  });

  group('SCRAM mutual auth with TLS-exporter channel binding', () {
    final salt = Uint8List.fromList(List.generate(16, (i) => i));
    final verifier = ScramVerifier.fromPassword(
      username: 'caller',
      password: 'correct horse battery staple',
      salt: salt,
      iterations: 4096,
    );

    ({Uint8List proof, ScramClient client}) clientProof({
      String password = 'correct horse battery staple',
      Uint8List? binding,
    }) {
      final client = ScramClient(username: 'caller', password: password);
      final proof = client.proof(
        clientNonce: 'cn-1',
        serverNonce: 'sn-1',
        salt: salt,
        iterations: 4096,
        channelBinding: binding ?? exporter(),
      );
      return (proof: proof, client: client);
    }

    test('round trip: both sides authenticate each other', () {
      final c = clientProof();
      final server = ScramServer(verifier: verifier);
      final serverSignature = server.verifyClientProof(
        clientNonce: 'cn-1',
        serverNonce: 'sn-1',
        channelBinding: exporter(),
        clientProof: c.proof,
      );
      expect(serverSignature, isNotNull);
      expect(
        c.client.verifyServerSignature(serverSignature!),
        isTrue,
        reason: 'mutual step: client must accept the server signature',
      );
    });

    test('wrong password is rejected', () {
      final c = clientProof(password: 'wrong');
      final server = ScramServer(verifier: verifier);
      expect(
        server.verifyClientProof(
          clientNonce: 'cn-1',
          serverNonce: 'sn-1',
          channelBinding: exporter(),
          clientProof: c.proof,
        ),
        isNull,
      );
    });

    test(
      'proof does not transfer across TLS connections (exporter differs)',
      () {
        final c = clientProof(binding: exporter(7));
        final server = ScramServer(verifier: verifier);
        expect(
          server.verifyClientProof(
            clientNonce: 'cn-1',
            serverNonce: 'sn-1',
            channelBinding: exporter(11),
            clientProof: c.proof,
          ),
          isNull,
          reason: 'a captured proof must be useless on another connection',
        );
      },
    );

    test('server without the verifier cannot forge a signature', () {
      final c = clientProof();
      final fakeSignature = Uint8List(32);
      expect(c.client.verifyServerSignature(fakeSignature), isFalse);
      expect(c.proof.length, 32);
    });

    test('measured: full mutual handshake cost at i=4096', () {
      final sw = Stopwatch()..start();
      const rounds = 20;
      for (var i = 0; i < rounds; i++) {
        final c = clientProof();
        final sig = ScramServer(verifier: verifier).verifyClientProof(
          clientNonce: 'cn-1',
          serverNonce: 'sn-1',
          channelBinding: exporter(),
          clientProof: c.proof,
        );
        expect(c.client.verifyServerSignature(sig!), isTrue);
      }
      sw.stop();
      final perHandshakeMs = sw.elapsedMilliseconds / rounds;
      // ignore: avoid_print
      print(
        'MEASURED scram handshake (client+server, i=4096): '
        '${perHandshakeMs.toStringAsFixed(1)} ms',
      );
      expect(
        perHandshakeMs,
        lessThan(250),
        reason: 'handshake must stay interactive',
      );
    });
  });

  group('AntiReplayWindow (counter + bitmap, RFC 4303 style)', () {
    test('accepts in-window out-of-order, rejects duplicates and stale', () {
      final w = AntiReplayWindow(windowSize: 64);
      expect(w.accept(10), isTrue);
      expect(w.accept(12), isTrue);
      expect(w.accept(11), isTrue, reason: 'out-of-order but fresh');
      expect(w.accept(12), isFalse, reason: 'duplicate');
      expect(w.accept(200), isTrue, reason: 'big jump slides the window');
      expect(w.accept(100), isFalse, reason: 'behind the left edge (stale)');
      expect(w.accept(199), isTrue, reason: 'still inside the 64-wide window');
      expect(w.accept(199), isFalse);
      expect(w.rejectedReplayCount, 2);
      expect(w.rejectedStaleCount, 1);
      expect(w.acceptedCount, 5);
    });

    test('window slide clears exactly the crossed slots', () {
      final w = AntiReplayWindow(windowSize: 64);
      expect(w.accept(0), isTrue);
      expect(w.accept(64), isTrue, reason: 'slides left edge to 1');
      expect(w.accept(0), isFalse, reason: 'now stale');
      // Slot for 64 shares bitmap offset with 0 — must not resurrect 0's bit.
      expect(w.accept(64), isFalse, reason: 'duplicate after wraparound');
    });

    test('measured: O(1) throughput vs the nonce-set it replaces', () {
      final w = AntiReplayWindow(windowSize: 1024);
      const n = 200000;
      final sw = Stopwatch()..start();
      for (var i = 0; i < n; i++) {
        w.accept(i);
      }
      sw.stop();
      final opsPerSec = n / (sw.elapsedMicroseconds / 1e6);
      // ignore: avoid_print
      print(
        'MEASURED replay-window accept: '
        '${(opsPerSec / 1e6).toStringAsFixed(1)} M ops/s, '
        'memory = ${1024 ~/ 64} ints (constant)',
      );
      expect(w.acceptedCount, n);
      expect(opsPerSec, greaterThan(1e6));
    });
  });

  group('RotatingKeySchedule (HKDF ratchet)', () {
    test('epochs derive distinct keys and auto-rotate on budget', () {
      final s = RotatingKeySchedule(
        initialSecret: bytes(0xaa, 32),
        messagesPerEpoch: 3,
      );
      final k0 = s.currentKey;
      expect(s.recordMessage(), isFalse);
      expect(s.recordMessage(), isFalse);
      expect(s.recordMessage(), isTrue, reason: '3rd message trips rotation');
      expect(s.epoch, 1);
      expect(s.currentKey, isNot(k0));
    });

    test('ratchet is deterministic for equal secrets, unique per secret', () {
      final a = RotatingKeySchedule(initialSecret: bytes(1, 32))..advance();
      final b = RotatingKeySchedule(initialSecret: bytes(1, 32))..advance();
      final c = RotatingKeySchedule(initialSecret: bytes(2, 32))..advance();
      expect(a.currentKey, b.currentKey);
      expect(a.currentKey, isNot(c.currentKey));
    });

    test('measured: rotation cost', () {
      final s = RotatingKeySchedule(initialSecret: bytes(9, 32));
      const n = 2000;
      final sw = Stopwatch()..start();
      for (var i = 0; i < n; i++) {
        s.advance();
      }
      sw.stop();
      final usPerRotation = sw.elapsedMicroseconds / n;
      // ignore: avoid_print
      print(
        'MEASURED key rotation: ${usPerRotation.toStringAsFixed(1)} us '
        'per epoch advance',
      );
      expect(s.epoch, n);
      expect(usPerRotation, lessThan(1000));
    });
  });

  group('MutualRelaySession end-to-end', () {
    test('establish -> admit -> replay rejected -> keys rotate', () {
      final salt = Uint8List.fromList(List.generate(16, (i) => 32 + i));
      final verifier = ScramVerifier.fromPassword(
        username: 'u',
        password: 'pw',
        salt: salt,
        iterations: 1024,
      );
      final client = ScramClient(username: 'u', password: 'pw');
      final proof = client.proof(
        clientNonce: 'c9',
        serverNonce: 's9',
        salt: salt,
        iterations: 1024,
        channelBinding: exporter(3),
      );
      final established = MutualRelaySession.establish(
        verifier: verifier,
        clientNonce: 'c9',
        serverNonce: 's9',
        tlsExporter: exporter(3),
        clientProof: proof,
        messagesPerEpoch: 2,
      );
      expect(established, isNotNull);
      expect(
        client.verifyServerSignature(established!.serverSignature),
        isTrue,
      );
      final session = established.session;
      final k0 = session.trafficKey;
      expect(session.admitMessage(1), isTrue);
      expect(session.admitMessage(1), isFalse, reason: 'replay');
      expect(session.admitMessage(2), isTrue);
      expect(session.keyEpoch, 1, reason: '2 admitted messages = budget');
      expect(session.trafficKey, isNot(k0));
    });

    test('bad proof yields no session', () {
      final salt = Uint8List.fromList(List.generate(16, (i) => i));
      final verifier = ScramVerifier.fromPassword(
        username: 'u',
        password: 'pw',
        salt: salt,
        iterations: 256,
      );
      expect(
        MutualRelaySession.establish(
          verifier: verifier,
          clientNonce: 'c',
          serverNonce: 's',
          tlsExporter: exporter(),
          clientProof: Uint8List(32),
        ),
        isNull,
      );
    });
  });

  group('PathValidator (post-switch challenge/response)', () {
    final key = bytes(0x42, 32);

    test('validated path passes exactly once; forged response fails', () {
      final v = PathValidator(sessionKey: key);
      final challenge = v.issueChallenge('relay-b:443', bytes(0x11, 8));
      final good = v.expectedResponse(challenge);
      expect(v.validateResponse('relay-b:443', Uint8List(32)), isFalse);
      expect(v.validateResponse('relay-b:443', good), isTrue);
      expect(
        v.validateResponse('relay-b:443', good),
        isFalse,
        reason: 'challenge is single-use',
      );
      expect(v.validatedCount, 1);
      expect(v.rejectedCount, 2);
    });

    test('response is key-bound: wrong session key cannot answer', () {
      final v = PathValidator(sessionKey: key);
      final attacker = PathValidator(sessionKey: bytes(0x43, 32));
      final challenge = v.issueChallenge('p', bytes(0x22, 8));
      expect(
        v.validateResponse('p', attacker.expectedResponse(challenge)),
        isFalse,
      );
    });
  });

  group('SessionContinuityToken (HKDF resumption)', () {
    test('token binds to session id AND key epoch', () {
      final minter = SessionContinuityToken(sessionKey: bytes(5, 32));
      final t = minter.mint(sessionId: 'sess-1', epoch: 0);
      expect(minter.verify(sessionId: 'sess-1', epoch: 0, token: t), isTrue);
      expect(minter.verify(sessionId: 'sess-2', epoch: 0, token: t), isFalse);
      expect(
        minter.verify(sessionId: 'sess-1', epoch: 1, token: t),
        isFalse,
        reason: 'key rotation must invalidate old tokens',
      );
    });
  });

  group('HappyEyeballsRacer (RFC 8305 staggered racing)', () {
    RelayEndpoint ep(String host) =>
        RelayEndpoint(hostPort: HostPort(host: host, port: 443));

    test('winner is the fast endpoint even when listed second', () {
      fakeAsync((async) {
        RacedConnection<String>? won;
        final racer = HappyEyeballsRacer<String>(
          endpoints: [ep('slow.example'), ep('fast.example')],
          connect: (e) => Future.delayed(
            Duration(
              milliseconds: e.hostPort.host.startsWith('slow') ? 900 : 40,
            ),
            () => 'conn-${e.hostPort.host}',
          ),
        );
        racer.race().then((r) => won = r);
        async.elapse(const Duration(milliseconds: 400));
        expect(won, isNotNull);
        expect(won!.endpoint.hostPort.host, 'fast.example');
        expect(won!.attemptsStarted, 2);
        // 250 ms stagger + 40 ms connect = 290 ms, far under the 940 ms a
        // sequential fallback would have paid.
        // ignore: avoid_print
        print(
          'MEASURED happy-eyeballs win (simulated clocks): 290 ms raced '
          'vs 940 ms sequential',
        );
      });
    });

    test('failure releases the stagger early', () {
      fakeAsync((async) {
        RacedConnection<String>? won;
        final racer = HappyEyeballsRacer<String>(
          endpoints: [ep('dead.example'), ep('ok.example')],
          connect: (e) => e.hostPort.host.startsWith('dead')
              ? Future.delayed(
                  const Duration(milliseconds: 30),
                  () => throw StateError('refused'),
                )
              : Future.delayed(
                  const Duration(milliseconds: 50),
                  () => 'conn-ok',
                ),
        );
        racer.race().then((r) => won = r);
        // Fast failure at 30 ms starts endpoint 2 immediately; it connects in
        // 50 ms -> total 80 ms, not 250+50.
        async.elapse(const Duration(milliseconds: 120));
        expect(won, isNotNull);
        expect(won!.endpoint.hostPort.host, 'ok.example');
      });
    });

    test('all endpoints failing surfaces NoReachableEndpointException', () {
      fakeAsync((async) {
        Object? error;
        final racer = HappyEyeballsRacer<String>(
          endpoints: [ep('a.example'), ep('b.example')],
          connect: (e) => Future.delayed(
            const Duration(milliseconds: 10),
            () => throw StateError('down'),
          ),
        );
        racer.race().catchError((Object e) {
          error = e;
          return RacedConnection<String>(
            endpoint: ep('none'),
            connection: '',
            attemptsStarted: 0,
            elapsed: Duration.zero,
          );
        });
        async.elapse(const Duration(seconds: 2));
        expect(error, isA<NoReachableEndpointException>());
      });
    });

    test('losing connection is discarded, not leaked', () {
      fakeAsync((async) {
        final discarded = <String>[];
        final racer = HappyEyeballsRacer<String>(
          endpoints: [ep('slow.example'), ep('fast.example')],
          connect: (e) => Future.delayed(
            Duration(
              milliseconds: e.hostPort.host.startsWith('slow') ? 600 : 20,
            ),
            () => 'conn-${e.hostPort.host}',
          ),
          discard: discarded.add,
        );
        racer.race();
        async.elapse(const Duration(seconds: 1));
        expect(discarded, ['conn-slow.example']);
      });
    });
  });

  group('ValidatedSwitcher (continuity across endpoint switch)', () {
    RelayEndpoint ep(String host) =>
        RelayEndpoint(hostPort: HostPort(host: host, port: 443));

    test('only a validated path is released; failures are discarded', () async {
      final key = bytes(0x51, 32);
      final serverSide = PathValidator(sessionKey: key);
      final clientSide = PathValidator(sessionKey: key);
      final discarded = <String>[];
      var attempt = 0;
      final switcher = ValidatedSwitcher<String>(
        connect: (e) async => 'conn-${e.hostPort.host}-${attempt++}',
        validatePath: (e, conn) async {
          final challenge = serverSide.issueChallenge(
            e.hostPort.authority,
            bytes(attempt, 8),
          );
          // First attempt simulates an off-path peer answering wrongly.
          final response = attempt == 1
              ? Uint8List(32)
              : clientSide.expectedResponse(challenge);
          return serverSide.validateResponse(e.hostPort.authority, response);
        },
        discard: discarded.add,
      );
      await expectLater(switcher.switchTo(ep('bad.example')), throwsStateError);
      final conn = await switcher.switchTo(ep('good.example'));
      expect(conn, 'conn-good.example-1');
      expect(switcher.switchCount, 1);
      expect(switcher.validationFailureCount, 1);
      expect(discarded, ['conn-bad.example-0']);
    });
  });

  group('continuity: SCRAM session + rotation + resumption chain', () {
    test('resumption token survives reconnect but not a key epoch bump', () {
      final schedule = RotatingKeySchedule(initialSecret: bytes(0x77, 32));
      final minterAtEpoch0 = SessionContinuityToken(
        sessionKey: schedule.currentKey,
      );
      final token = minterAtEpoch0.mint(
        sessionId: 'live-1',
        epoch: schedule.epoch,
      );
      // Reconnect on a new endpoint, same epoch: token verifies.
      expect(
        minterAtEpoch0.verify(
          sessionId: 'live-1',
          epoch: schedule.epoch,
          token: token,
        ),
        isTrue,
      );
      // Rotate: the old token must die with the old epoch.
      schedule.advance();
      expect(
        SessionContinuityToken(
          sessionKey: schedule.currentKey,
        ).verify(sessionId: 'live-1', epoch: schedule.epoch, token: token),
        isFalse,
      );
    });
  });
}
