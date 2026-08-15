import 'package:signed_config/signed_config.dart';
import 'package:test/test.dart';

import 'support/fakes.dart';

/// Ticket 3 gate 3f — the code-provable half.
///
/// Under a relay-only policy the ICE agent gathers relay candidates only, so
/// the device's own network address is never offered to the peer. Under
/// `'all'` it gathers host and server-reflexive candidates too, and the local
/// address goes out. The policy string is therefore the whole of the
/// guarantee at this layer, and this file pins it: which inputs produce
/// `'relay'`, which produce `'all'`, and that no path produces a relay-only
/// policy with nothing to relay through.
///
/// What this file does NOT prove: that the agent below this layer honours the
/// string. That is a packet capture on real hardware, and it is a wave-7 rig
/// row — see the plan. A green result here licenses "the configuration asked
/// for relay-only", never "no host candidate left the device".
void main() {
  IceServerEntry stun(String host) =>
      IceServerEntry(urls: [Uri.parse('stun:$host:3478')]);

  IceServerEntry turns(String host) => IceServerEntry(
    urls: [Uri.parse('turns:$host:443')],
    username: 'u',
    credential: 'c',
  );

  EndpointManifest manifestWith(
    List<IceServerEntry> servers, {
    Map<String, bool> flags = const {},
  }) => buildManifest(
    revision: 1,
    iceServers: servers,
    featureFlags: flags,
  );

  group('gate 3f — which inputs actually reach a relay-only policy', () {
    test('the default profile offers host candidates, by design', () {
      final config = buildRtcIceConfig(
        manifestWith([turns('r.example'), stun('s.example')]),
      );
      expect(
        config.iceTransportPolicy,
        'all',
        reason: 'a normal call wants every path that might work; the local '
            'address going out is the cost of that and is not a defect',
      );
    });

    test('the strict profile is relay-only', () {
      final config = buildRtcIceConfig(
        manifestWith([turns('r.example'), stun('s.example')]),
        profile: IceProfile.strictRelay,
      );
      expect(config.iceTransportPolicy, 'relay');
      expect(
        config.iceServers.every(
          (s) => (s['urls']! as List).every(
            (u) => '$u'.startsWith('turn'),
          ),
        ),
        isTrue,
        reason: 'a relay-only policy with a STUN entry in the list is a '
            'contradiction the mapper must not emit',
      );
    });

    test('a manifest flag reaches the strict profile', () {
      final profile = iceProfileFor(
        iceFailureCount: 0,
        featureFlags: const {'strict_relay': true},
      );
      expect(profile, IceProfile.strictRelay);
    });

    test(
      'the failure count reaches the strict profile at two, and only at two',
      () {
        for (final (count, expected) in <(int, IceProfile)>[
          (0, IceProfile.normal),
          (1, IceProfile.normal),
          (2, IceProfile.strictRelay),
          (7, IceProfile.strictRelay),
        ]) {
          expect(
            iceProfileFor(iceFailureCount: count, featureFlags: const {}),
            expected,
            reason: 'count=$count',
          );
        }
      },
    );

    test(
      'no input produces a relay-only policy with nothing to relay through',
      () {
        // The one way to reach that state is a strict profile over a manifest
        // holding no relay entry, and it is refused rather than emitted.
        for (final servers in <List<IceServerEntry>>[
          [],
          [stun('a.example')],
          [stun('a.example'), stun('b.example')],
        ]) {
          expect(
            () => buildRtcIceConfig(
              manifestWith(servers),
              profile: IceProfile.strictRelay,
            ),
            throwsA(isA<StrictRelayUnsatisfiableException>()),
            reason: 'servers=${servers.length}',
          );
        }
      },
    );
  });
}
