/// The device binding seam: null-safe in the demo build, live when a real
/// radio binding is injected.
library;

import 'dart:io';

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

  group('intelligenceStorageBase', () {
    const iosTmp = '/private/var/mobile/Containers/Data/Application/AB12/tmp/';
    const iosDocs =
        '/private/var/mobile/Containers/Data/Application/AB12/Documents'
        '/voice_call_kit_intelligence';

    test("iOS: Documents is tmp's sibling, HOME is irrelevant", () {
      for (final env in const [
        <String, String>{},
        <String, String>{'HOME': ''},
        <String, String>{'HOME': '/elsewhere'},
      ]) {
        expect(
          intelligenceStorageBase(
            isIOS: true,
            isAndroid: false,
            systemTempPath: iosTmp,
            environment: env,
          ),
          iosDocs,
        );
      }
    });

    test('Android: HOME/Documents when set, null without HOME, and the iOS '
        'sibling trick is never applied', () {
      expect(
        intelligenceStorageBase(
          isAndroid: true,
          isIOS: false,
          systemTempPath: '/data/user/0/pkg/cache',
          environment: const {'HOME': '/data/user/0/pkg'},
        ),
        '/data/user/0/pkg/Documents/voice_call_kit_intelligence',
      );
      // No HOME: null — NOT the cache dir's sibling Documents.
      expect(
        intelligenceStorageBase(
          isAndroid: true,
          isIOS: false,
          systemTempPath: '/data/user/0/pkg/cache',
          environment: const {},
        ),
        isNull,
      );
    });

    test('desktop/test: always null, whatever the tmp or HOME', () {
      expect(
        intelligenceStorageBase(
          isIOS: false,
          isAndroid: false,
          systemTempPath: '/tmp/host',
          environment: const {'HOME': '/home/me'},
        ),
        isNull,
      );
      // Pins bootIntelligence's system-temp default on the host.
      expect(buildStorageDirectory(), isNull);
    });

    test('the identity file: Application Support under HOME on a Mac, the '
        'shared folder everywhere else and under flutter test', () {
      expect(
        identityStorageBase(
          isMacOS: true,
          environment: const {'HOME': '/Users/me/Library/Containers/app/Data/'},
        ),
        '/Users/me/Library/Containers/app/Data/Library/Application Support/'
        'voice_call_kit_intelligence',
      );
      expect(identityStorageBase(isMacOS: true, environment: const {}), isNull);
      expect(
        identityStorageBase(
          isMacOS: true,
          environment: const {'HOME': '/Users/me', 'FLUTTER_TEST': 'true'},
        ),
        isNull,
      );
      expect(
        identityStorageBase(
          isMacOS: false,
          environment: const {'HOME': '/home/me'},
        ),
        isNull,
      );
      // This very process is a flutter test: nothing lands in a real home.
      expect(
        identityStorageDirectory().path,
        intelligenceStorageDirectory().path,
      );
    });

    test('card and parked-letter queue share one base', () {
      expect(
        letterQueueDirectory().parent.path,
        intelligenceStorageDirectory().path,
      );
    });

    test('the factory creates the iOS Documents folder on first call', () {
      final root = Directory.systemTemp.createTempSync('intel_base_test');
      try {
        final base = intelligenceStorageBase(
          isIOS: true,
          isAndroid: false,
          systemTempPath: '${root.path}/tmp',
          environment: const {},
        );
        expect(base, '${root.path}/Documents/voice_call_kit_intelligence');
        final dir = Directory(base!)..createSync(recursive: true);
        expect(dir.existsSync(), isTrue);
      } finally {
        root.deleteSync(recursive: true);
      }
    });
  });
}
