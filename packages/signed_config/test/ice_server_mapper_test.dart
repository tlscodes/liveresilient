import 'package:signed_config/src/endpoint_manifest.dart';
import 'package:signed_config/src/ice_server_mapper.dart';
import 'package:test/test.dart';

EndpointManifest _manifest(
  List<IceServerEntry> ice, {
  Map<String, bool>? flags,
}) => EndpointManifest(
  schemaVersion: manifestSchemaVersion,
  revision: 1,
  signingKeyId: 'k1',
  issuedAt: DateTime.utc(2026, 1, 1),
  expiresAt: DateTime.utc(2027, 1, 1),
  signalingEndpoints: [Uri.parse('wss://a.example/ws')],
  iceServers: ice,
  configServiceUris: [Uri.parse('https://a.example/cfg')],
  relayRegions: const [],
  featureFlags: flags ?? const {},
  minimumAppVersion: '',
);

IceServerEntry _e(List<String> urls, {String user = '', String cred = ''}) =>
    IceServerEntry(
      urls: [for (final u in urls) Uri.parse(u)],
      username: user,
      credential: cred,
    );

void main() {
  group('buildRtcIceConfig', () {
    test('maps urls and credentials into the shape create() takes', () {
      final cfg = buildRtcIceConfig(
        _manifest([
          _e(['turns:relay.example:443?transport=tcp'], user: 'u', cred: 'c'),
        ]),
      );
      expect(cfg.iceServers, hasLength(1));
      expect(
        cfg.iceServers.single['urls'],
        equals(['turns:relay.example:443?transport=tcp']),
      );
      expect(cfg.iceServers.single['username'], 'u');
      expect(cfg.iceServers.single['credential'], 'c');
    });

    test('omits empty credential keys rather than sending blanks', () {
      final cfg = buildRtcIceConfig(
        _manifest([
          _e(['stun:stun.example:3478']),
        ]),
      );
      expect(cfg.iceServers.single.containsKey('username'), isFalse);
      expect(cfg.iceServers.single.containsKey('credential'), isFalse);
    });

    test(
      'orders turns-443 first, then turns, turn, stun — and drops nothing',
      () {
        final cfg = buildRtcIceConfig(
          _manifest([
            _e(['stun:stun.example:3478']),
            _e(['turn:relay.example:3478'], user: 'u', cred: 'c'),
            _e(['turns:relay.example:5349'], user: 'u', cred: 'c'),
            _e(['turns:relay.example:443?transport=tcp'], user: 'u', cred: 'c'),
          ]),
        );
        final first = (cfg.iceServers[0]['urls']! as List).first as String;
        final second = (cfg.iceServers[1]['urls']! as List).first as String;
        final last = (cfg.iceServers.last['urls']! as List).first as String;
        expect(first, contains(':443'));
        expect(second, startsWith('turns:'));
        expect(last, startsWith('stun:'));
        expect(
          cfg.iceServers,
          hasLength(4),
          reason: 'ordering must not filter',
        );
        expect(cfg.iceTransportPolicy, 'all');
      },
    );

    test('strictRelay forces relay policy and drops stun-only entries', () {
      final cfg = buildRtcIceConfig(
        _manifest([
          _e(['stun:stun.example:3478']),
          _e(['turn:relay.example:3478'], user: 'u', cred: 'c'),
        ]),
        profile: IceProfile.strictRelay,
      );
      expect(cfg.iceTransportPolicy, 'relay');
      expect(cfg.iceServers, hasLength(1));
      expect(
        (cfg.iceServers.single['urls']! as List).single,
        'turn:relay.example:3478',
      );
    });

    test('an entry carrying both stun and turn urls survives strictRelay', () {
      final cfg = buildRtcIceConfig(
        _manifest([
          _e(
            ['stun:relay.example:3478', 'turns:relay.example:443'],
            user: 'u',
            cred: 'c',
          ),
        ]),
        profile: IceProfile.strictRelay,
      );
      expect(cfg.iceServers, hasLength(1));
    });

    test('an empty manifest list yields an empty list, not a crash', () {
      final cfg = buildRtcIceConfig(_manifest(const []));
      expect(cfg.iceServers, isEmpty);
      expect(cfg.iceTransportPolicy, 'all');
    });
  });

  group('iceProfileFor', () {
    test('normal by default — relaying everything is never the default', () {
      expect(
        iceProfileFor(iceFailureCount: 0, featureFlags: const {}),
        IceProfile.normal,
      );
      expect(
        iceProfileFor(iceFailureCount: 1, featureFlags: const {}),
        IceProfile.normal,
      );
    });

    test('two failures on the same call escalate to relay-only', () {
      expect(
        iceProfileFor(iceFailureCount: 2, featureFlags: const {}),
        IceProfile.strictRelay,
      );
    });

    test('the manifest flag can force it regardless of failures', () {
      expect(
        iceProfileFor(
          iceFailureCount: 0,
          featureFlags: const {'strict_relay': true},
        ),
        IceProfile.strictRelay,
      );
    });
  });
}
