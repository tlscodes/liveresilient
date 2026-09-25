/// The device binding seam: null-safe in the demo build, live when a real
/// radio binding is injected.
library;

import 'package:adaptive_transport/adaptive_transport.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reference_app/src/intelligence/device_bindings.dart';
import 'package:reference_app/src/intelligence/local_link_lane.dart';

void main() {
  test('demo build wires no link lane', () {
    expect(buildLocalLinkLane(), isNull);
  });

  test('injecting a real binding produces a live link lane', () {
    final lane = buildLocalLinkLane(
      binding: LocalLinkBinding(
        discoverAndConnect: () async => true,
        sendBytes: (_) async => true,
        peerCount: () => 1,
      ),
    );
    expect(lane, isA<TransportChannel>());
    expect(lane!.name, 'local-link');
  });

  test('link relay consent defaults off and flips on opt-in', () async {
    final consent = LinkRelayConsent();
    expect(consent.granted, isFalse);

    final lane = buildLocalLinkLane(
      binding: LocalLinkBinding(
        discoverAndConnect: () async => true,
        sendBytes: (_) async => true,
        peerCount: () => 1,
      ),
      consent: consent,
    )!;
    // Consent still off → the lane refuses to move bytes.
    expect((await lane.send([1])).status, SendStatus.unavailable);

    consent.setGranted(true);
    expect((await lane.send([1])).status, SendStatus.ok);
  });

  group('systemDnsResolverBinding', () {
    test('no probe bound: the demo/test build, unchanged', () {
      expect(
        systemDnsResolverBinding(
          existingSystemResolvers: const [HostPort(host: '10.0.0.1', port: 53)],
        ),
        isEmpty,
      );
      expect(systemDnsResolverBinding(), isEmpty);
    });

    test('resolv.conf already answered: never widened, even with a '
        'probe bound', () {
      final resolvers = systemDnsResolverBinding(
        probe: () => const HostPort(host: '203.0.113.9', port: 53),
        existingSystemResolvers: const [HostPort(host: '10.0.0.1', port: 53)],
      );
      expect(resolvers, isEmpty);
    });

    test('resolv.conf empty and a probe names the device\'s own resolver: '
        'that one, and only that one, is added', () {
      final resolvers = systemDnsResolverBinding(
        probe: () => const HostPort(host: '203.0.113.9', port: 53),
      );
      expect(resolvers, [const HostPort(host: '203.0.113.9', port: 53)]);
    });

    test('a probe naming nothing yet is not published, not a crash', () {
      expect(systemDnsResolverBinding(probe: () => null), isEmpty);
    });

    test('a throwing probe is not published, not a crash', () {
      expect(
        systemDnsResolverBinding(probe: () => throw StateError('no radio')),
        isEmpty,
      );
    });
  });
}
