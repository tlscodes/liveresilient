import 'dart:io';

import 'package:adaptive_transport/adaptive_transport.dart'
    show TxtQueryLane, TxtQueryResolvers, TxtQueryValve;
import 'package:call_core/call_core.dart' show CallRole;
import 'package:connection_orchestrator/connection_orchestrator.dart';
import 'package:device_link/device_link.dart' show DtnBundleQueue;
import 'package:flutter_test/flutter_test.dart';
import 'package:reference_app/src/call_session.dart';

ConnectionFabric _fabric() => ConnectionFabric(
  fallbackQueue: DtnBundleQueue(),
  nowMs: () => DateTime.now().millisecondsSinceEpoch,
);

void main() {
  test('the valve is configured by its zone, not by the host platform', () {
    final endpoints = defaultBorderRelayEndpoints(
      callId: 'call-1',
      role: CallRole.initiator,
    );

    // The only condition is whether a zone was named for this build. There
    // is no platform test left in the path: the lane is a UDP socket and a
    // DNS message, which iOS and Android both have.
    expect(endpoints.txtQueryValve == null, txtQueryValveDomain == null);
    if (txtQueryValveDomain != null) {
      expect(endpoints.txtQueryValve!.domain, txtQueryValveDomain);
    }
  });

  test('the app reads the zone the environment names', () {
    final fromEnvironment = Platform.environment['DNS_VALVE_DOMAIN']?.trim();

    if (fromEnvironment == null || fromEnvironment.isEmpty) {
      expect(txtQueryValveDomain, isNull);
    } else {
      expect(txtQueryValveDomain, fromEnvironment);
    }
  });

  test('the fabric registers the lane behind both WAN lanes', () {
    final fabric = _fabric();
    addTearDown(() => ResilientFallbackLanes.unregisterAll(fabric));
    final relay = defaultBorderRelayEndpoints(
      callId: 'call-1',
      role: CallRole.receiver,
    );
    final endpoints = ResilientLaneEndpoints(
      relayUri: relay.relayUri,
      longPollUri: relay.longPollUri,
      txtQueryValve: const TxtQueryValve(domain: 'valve.example'),
    );

    final ids = ResilientFallbackLanes.buildAndRegister(fabric, endpoints);

    expect(ids, contains(ResilientLaneIds.txtQuery));
    expect(
      ids.indexOf(ResilientLaneIds.txtQuery),
      greaterThan(ids.indexOf(ResilientLaneIds.httpLongPoll)),
    );
  });

  test('a build with no zone named registers no DNS lane', () {
    final fabric = _fabric();
    addTearDown(() => ResilientFallbackLanes.unregisterAll(fabric));
    final relay = defaultBorderRelayEndpoints(
      callId: 'call-1',
      role: CallRole.initiator,
    );

    final ids = ResilientFallbackLanes.buildAndRegister(
      fabric,
      ResilientLaneEndpoints(
        relayUri: relay.relayUri,
        longPollUri: relay.longPollUri,
      ),
    );

    expect(ids, isNot(contains(ResilientLaneIds.txtQuery)));
  });

  test('this device always has somewhere to aim the lane', () {
    // On a phone the system list is empty and the public resolvers are the
    // whole candidate list; on this desktop resolv.conf usually adds one in
    // front. Either way the lane is never left with no endpoint.
    final candidates = TxtQueryResolvers.candidates();

    expect(candidates, isNotEmpty);
    expect(candidates, containsAll(TxtQueryResolvers.publicResolvers));
  });

  test('the lane a phone would build has a UDP and a DoH path', () async {
    final lane = TxtQueryLane.forValve(
      const TxtQueryValve(domain: 'valve.example'),
    );
    addTearDown(lane.dispose);

    // Nothing was sent, so nothing is claimed about reachability — only
    // that the lane came up with both kinds of path available to rotate
    // through, which is what makes it usable off a desktop.
    expect(lane.currentTransport.label, startsWith('udp53:'));
    expect(lane.isDown, isFalse);
    expect(TxtQueryResolvers.publicDohEndpoints, isNotEmpty);
  });
}
