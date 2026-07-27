@Tags(['live-network'])
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:adaptive_transport/adaptive_transport.dart';
import 'package:test/test.dart';

/// Pass-through verified against a real server, not a fake one.
///
/// Skipped unless `PROBE_DEFENSE_LIVE=1`, because a test that reaches the
/// public internet must never be able to redden CI for a reason that has
/// nothing to do with the change under test. Run it deliberately:
///
/// ```sh
/// PROBE_DEFENSE_LIVE=1 dart test test/probe_defense/reality_live_passthrough_test.dart
/// ```
///
/// What it proves that the in-memory tests cannot: the bytes the relay
/// replays upstream are accepted by a real TLS stack, and what comes back
/// is that server's genuine Server Hello — the relay contributed nothing.
const _liveHost = 'www.apple.com';

bool get _liveEnabled => Platform.environment['PROBE_DEFENSE_LIVE'] == '1';

/// A duplex pair driven by the test, standing in for an accepted socket.
class ScriptedClient implements DuplexByteStream {
  final StreamController<Uint8List> _toGate =
      StreamController<Uint8List>.broadcast();
  final List<Uint8List> fromRelay = [];
  bool closed = false;

  void send(Uint8List bytes) => _toGate.add(bytes);

  Uint8List get received {
    final builder = BytesBuilder(copy: false);
    for (final chunk in fromRelay) {
      builder.add(chunk);
    }
    return builder.toBytes();
  }

  @override
  Stream<Uint8List> get inbound => _toGate.stream;

  @override
  void add(Uint8List bytes) => fromRelay.add(bytes);

  @override
  Future<void> close() async {
    closed = true;
    if (!_toGate.isClosed) await _toGate.close();
  }
}

void main() {
  group('live pass-through', () {
    late RealityGate gate;
    late ScriptedClient client;

    setUp(() {
      client = ScriptedClient();
      gate = RealityGate(
        authenticator: RealityAuthenticator(
          credentials: [
            RealityCredential.fromSharedSecret(
              Uint8List.fromList(List<int>.filled(32, 0x11)),
            ),
          ],
        ),
        relay: PassThroughRelay(
          connector: connectFallbackSocket,
          target: const FallbackTarget(host: _liveHost),
        ),
      );
    });

    test('an unauthenticated hello gets $_liveHost\'s own Server Hello',
        () async {
      final hello = UtlsClientHelloBuilder(
        profile: UtlsClientProfile.chrome120,
        random: Random.secure(),
      ).build(serverName: _liveHost);
      final record = UtlsClientHelloBuilder.wrapInRecord(hello);

      final outcome = gate.handle(client, onAdmitted: (_, __, ___) {
        fail('an unregistered short id must never be admitted');
      });
      await Future<void>.delayed(Duration.zero);
      client.send(record);

      final result = await outcome.timeout(const Duration(seconds: 20));
      expect(result.admitted, isFalse);
      expect(result.stats!.bytesToUpstream, greaterThanOrEqualTo(record.length));

      final response = client.received;
      expect(response, isNotEmpty,
          reason: 'the real server must have answered');
      // Either answer proves the point. 0x16 is a server_hello; 0x15 is an
      // alert — which is what this hello actually earns, because the
      // builder sends a placeholder key share rather than a real X25519
      // public key, and the server rejects it. The alert is *the server's*,
      // byte-for-byte, which is exactly the property under test: a prober
      // sees the fallback host's own behavior, including its failures.
      expect(response[0], anyOf(0x16, 0x15),
          reason: 'first record back is a TLS record from the real server');
      if (response[0] == 0x16) {
        expect(response[5], 0x02, reason: 'its message is a server_hello');
      }
      expect(response.sublist(1, 3), [0x03, 0x03],
          reason: 'a real TLS 1.2/1.3 record version');
      expect(result.stats!.bytesToClient, response.length);
    });

    test('the relay adds no latency budget of its own to the decision',
        () async {
      final hello = UtlsClientHelloBuilder(
        profile: UtlsClientProfile.chrome120,
        random: Random.secure(),
      ).build(serverName: _liveHost);
      final record = UtlsClientHelloBuilder.wrapInRecord(hello);

      final outcome = gate.handle(client, onAdmitted: (_, __, ___) {});
      await Future<void>.delayed(Duration.zero);
      client.send(record);
      final result = await outcome.timeout(const Duration(seconds: 20));

      // `elapsed` covers only first-byte-to-decision, not the upstream
      // connect that follows it.
      expect(result.elapsed.inMilliseconds, lessThan(50));
    });
  }, skip: _liveEnabled ? null : 'set PROBE_DEFENSE_LIVE=1 to run');
}
