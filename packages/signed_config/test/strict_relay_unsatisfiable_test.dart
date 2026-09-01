import 'package:signed_config/signed_config.dart';
import 'package:test/test.dart';

import 'support/fakes.dart';

/// Ticket 3 gate 3b.
///
/// Under the strict profile the mapper drops every entry that carries no
/// relay URL. When the manifest holds only STUN entries that filter empties
/// the list, and the old code returned a well-formed configuration with an
/// empty server list and a relay-only policy: a configuration that can gather
/// no candidates at all. Nothing said so. The caller learned about it as a
/// connection that never completed, with no reason attached.
void main() {
  EndpointManifest manifestWith(List<IceServerEntry> servers) =>
      buildManifest(revision: 1, iceServers: servers);

  IceServerEntry stun(String host) =>
      IceServerEntry(urls: [Uri.parse('stun:$host:3478')]);

  IceServerEntry turns(String host) => IceServerEntry(
    urls: [Uri.parse('turns:$host:443')],
    username: 'u',
    credential: 'c',
  );

  group('gate 3b — strict relay with no relay servers', () {
    test('3b  a STUN-only manifest under strict is an explicit failure', () {
      final manifest = manifestWith([stun('a.example'), stun('b.example')]);
      expect(
        () => buildRtcIceConfig(manifest, profile: IceProfile.strictRelay),
        throwsA(isA<StrictRelayUnsatisfiableException>()),
        reason:
            'an empty server list under a relay-only policy cannot gather '
            'a single candidate; returning it as a valid config hides that',
      );
    });

    test('3b  the failure reports how many entries the filter removed', () {
      final manifest = manifestWith([
        stun('a.example'),
        stun('b.example'),
        stun('c.example'),
      ]);
      try {
        buildRtcIceConfig(manifest, profile: IceProfile.strictRelay);
        fail('expected StrictRelayUnsatisfiableException');
      } on StrictRelayUnsatisfiableException catch (e) {
        expect(e.droppedEntryCount, 3);
        expect(e.toString(), contains('3'));
      }
    });

    test('3b  strict with at least one relay is unchanged', () {
      final manifest = manifestWith([stun('a.example'), turns('r.example')]);
      final config = buildRtcIceConfig(
        manifest,
        profile: IceProfile.strictRelay,
      );
      expect(config.iceTransportPolicy, 'relay');
      expect(config.iceServers, hasLength(1));
      expect(
        (config.iceServers.single['urls']! as List).single,
        contains('turns:'),
      );
    });

    test(
      '3b  the non-strict path is untouched: every server is still offered',
      () {
        final manifest = manifestWith([stun('a.example'), turns('r.example')]);
        final config = buildRtcIceConfig(manifest);
        expect(config.iceTransportPolicy, 'all');
        expect(
          config.iceServers,
          hasLength(2),
          reason:
              'ordering expresses preference; dropping a server can only '
              'lose a path that might have worked',
        );
        expect(
          (config.iceServers.first['urls']! as List).single,
          contains('turns:'),
          reason: 'turns on 443 ranks first',
        );
      },
    );

    test('3b  a STUN-only manifest is fine when the profile is not strict', () {
      final manifest = manifestWith([stun('a.example')]);
      final config = buildRtcIceConfig(manifest);
      expect(config.iceServers, hasLength(1));
      expect(config.iceTransportPolicy, 'all');
    });
  });
}
