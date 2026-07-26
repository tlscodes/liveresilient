/// The device binding seam: null-safe in the demo build, live when a real
/// radio binding is injected.
library;

import 'package:adaptive_transport/adaptive_transport.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reference_app/src/intelligence/device_bindings.dart';
import 'package:reference_app/src/intelligence/local_link_lane.dart';

void main() {
  test('demo build wires no link lane and no LLM engine', () {
    expect(buildLocalLinkLane(), isNull);
    expect(buildLlmEngine(), isNull);
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
}
