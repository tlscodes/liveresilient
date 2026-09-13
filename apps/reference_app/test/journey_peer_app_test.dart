/// Pins the arm-time gate of the phone peer's blackout job: a plan that can
/// never deliver is rejected before a bundle is queued, with the error text
/// the `failed` report carries.
///
/// Scenario pinned (refuter finding, journey_peer_app.dart:540): the runner
/// started with JOURNEY_BLACKOUT_STREAM_PORT=0, so job.json carried
/// "stream":{"port":0,...}. BlackoutPlan.parse yields a full item list (a
/// stream map exists), portOf() yields null, and without the gate every probe
/// hit the "plan carries no stream port" early return in _streamFlush for the
/// whole lifetime_s (default 21600 s) before the phone reported failed.
library;

import 'package:flutter_test/flutter_test.dart';

import '../integration_test/blackout_forwarder.dart';
import '../integration_test/journey_peer_app.dart';
import '../integration_test/whitelist_door.dart';

void main() {
  const plan = [
    {'kind': 'text', 'bytes': 200, 'n': 2},
    {'kind': 'photo', 'bytes': 45000, 'n': 1},
  ];

  Map<String, Object?> stream(Object? port) => {
    'port': port,
    'piece_bytes': 8192,
    'ack_bytes': 8192,
    'ack_interval_s': 2,
    'inflight_bytes': 32768,
    'stall_s': 15,
  };

  test('a v3 plan with a usable stream port is accepted', () {
    final v3 = BlackoutPlan.parse({
      'v': 3,
      'plan': plan,
      'stream': stream(8766),
    })!;
    expect(v3.items.length, 3);
    expect(blackoutPlanRejection(v3), isNull);
  });

  test('a v3 plan whose stream map has port 0 is rejected at arm time', () {
    // The exact shape JOURNEY_BLACKOUT_STREAM_PORT=0 produces: items parse
    // (a stream map exists) but the port is unusable.
    final v3 = BlackoutPlan.parse({'v': 3, 'plan': plan, 'stream': stream(0)})!;
    expect(v3.items.length, 3, reason: 'parse keeps the items');
    expect(
      blackoutPlanRejection(v3),
      'blackout v3 plan carries no stream port',
    );
  });

  test('absent, out-of-range and non-int ports are rejected the same way', () {
    for (final port in <Object?>[null, -1, 65536, '8766', 8766.0]) {
      final v3 = BlackoutPlan.parse({
        'v': 3,
        'plan': plan,
        'stream': stream(port),
      })!;
      expect(v3.items.length, 3, reason: 'port=$port');
      expect(
        blackoutPlanRejection(v3),
        'blackout v3 plan carries no stream port',
        reason: 'port=$port',
      );
    }
    final noPortKey = BlackoutPlan.parse({
      'v': 3,
      'plan': plan,
      'stream': <String, Object?>{'piece_bytes': 8192},
    })!;
    expect(
      blackoutPlanRejection(noPortKey),
      'blackout v3 plan carries no stream port',
    );
  });

  test('a v3 plan without a stream map is rejected as empty', () {
    final v3 = BlackoutPlan.parse({'v': 3, 'plan': plan})!;
    expect(v3.items, isEmpty);
    expect(blackoutPlanRejection(v3), 'blackout v3 plan is empty');
  });

  test('v2 plans never need a stream port; an empty v2 plan is rejected', () {
    final v2 = BlackoutPlan.parse({'v': 2, 'plan': plan})!;
    expect(blackoutPlanRejection(v2), isNull);
    final v2WithPortZero = BlackoutPlan.parse({
      'v': 2,
      'plan': plan,
      'stream': stream(0),
    })!;
    expect(blackoutPlanRejection(v2WithPortZero), isNull);
    final v2Empty = BlackoutPlan.parse({'v': 2, 'plan': <Object?>[]})!;
    expect(blackoutPlanRejection(v2Empty), 'blackout v2 plan is empty');
  });

  // --- the whitelist profile's job wiring (refuter finding, 2026-09-05) ---
  //
  // The finding said the phone-side wiring was still an unapplied patch, so
  // the `"whitelist":{...}` map tools/t2/journey_run.sh:143-152 posts would be
  // discarded and the profile could not produce a row at all. The wiring is in
  // the file at HEAD (journey_peer_app.dart:85 the field, :106 and :112 the
  // parse, :315-327 the arm-time config gate, :329-341 the relay-only ICE,
  // :342-350 the door loop and the two controls). These tests pin it, so a
  // peer that loses the field again fails here rather than on the rig, after a
  // filter load, a coturn start and a ~20 min build.

  // The string tools/t2/journey_run.sh:143-152 prints for this profile with
  // its documented defaults: RELAY_PORT 4443, WHITELIST_DOOR_INTERVAL_S 1,
  // blocked host 192.168.2.9, rst and quic port 443, quic timeout 3000 ms.
  const runnerJobJson =
      '{"run":"r1","key":"k1","hold_s":700,"profile":"whitelist",'
      '"whitelist":{"url":"https://192.168.2.1:4443/","interval_s":1,'
      '"blocked_host":"192.168.2.9","rst_port":443,"quic_port":443,'
      '"quic_timeout_ms":3000,"relay_only":true}}';

  test('the whitelist job the runner posts reaches the peer intact', () {
    final job = JourneyJob.tryParse(runnerJobJson)!;
    expect(job.run, 'r1');
    expect(job.key, 'k1');
    expect(job.holdS, 700);
    expect(job.blackout, isNull, reason: 'the queue path stays unbuilt');
    expect(job.whitelist, isNotNull, reason: 'the map must not be discarded');
    final config = WhitelistDoorConfig.parse(job.whitelist!);
    expect(config.url, 'https://192.168.2.1:4443/');
    expect(config.interval, const Duration(seconds: 1));
    expect(config.blockedHost, '192.168.2.9');
    expect(config.rstPort, 443);
    expect(config.quicPort, 443);
    expect(config.quicTimeout, const Duration(milliseconds: 3000));
    expect(config.relayOnly, isTrue, reason: 'ICE is forced relay-only');
  });

  test('a job without a whitelist map leaves the door absent', () {
    final job = JourneyJob.tryParse(
      '{"run":"r1","key":"k1","hold_s":400,"profile":"normal"}',
    )!;
    expect(job.whitelist, isNull);
    expect(job.blackout, isNull);
  });

  test('a whitelist value that is not a map is ignored, never a crash', () {
    final job = JourneyJob.tryParse(
      '{"run":"r1","key":"k1","hold_s":400,"whitelist":"yes"}',
    )!;
    expect(job.whitelist, isNull);
  });

  test('a whitelist map without url is rejected at arm time', () {
    expect(
      () => WhitelistDoorConfig.parse(const <String, Object?>{'interval_s': 1}),
      throwsA(isA<FormatException>()),
    );
  });

  // --- the dnsvalve profile's job wiring (2026-09-13) ---
  //
  // The peer's call path builds an E2eCallStack, which constructs no
  // ConnectionFabric, so this build's DNS_VALVE_* defines carry no lane on
  // their own: the `dns_valve` map is what makes the peer register one. A
  // peer that discards the map produces no `lane` event at all, and the Mac
  // then reports a branch that never ran — after a rig hour. These pin the
  // parse so that failure lands here instead.

  const dnsValveJobJson =
      '{"run":"r2","key":"k2","hold_s":700,"profile":"dnsvalve",'
      '"dns_valve":{"zone":"valve.example","resolvers":["192.168.2.1:5300"],'
      '"chat_bytes":64,"select_budget_s":90,"carry_budget_s":150,'
      '"relay_only":true}}';

  test('a job without dns_valve parses exactly as before', () {
    final job = JourneyJob.tryParse(
      '{"run":"r1","key":"k1","hold_s":400,"profile":"normal"}',
    )!;
    expect(job.run, 'r1');
    expect(job.key, 'k1');
    expect(job.holdS, 400);
    expect(job.dnsValve, isNull, reason: 'no fabric branch is armed');
    expect(job.whitelist, isNull);
    expect(job.blackout, isNull);
  });

  test('the dnsvalve job the runner posts reaches the peer intact', () {
    final job = JourneyJob.tryParse(dnsValveJobJson)!;
    expect(job.run, 'r2');
    expect(job.key, 'k2');
    expect(job.holdS, 700);
    expect(job.blackout, isNull, reason: 'the call is placed, not replaced');
    expect(job.whitelist, isNull);
    expect(job.dnsValve, isNotNull, reason: 'the map must not be discarded');

    final config = DnsValveConfig.parse(job.dnsValve!);
    expect(config.zone, 'valve.example');
    expect(config.resolvers.length, 1);
    expect(config.resolvers.single.host, '192.168.2.1');
    expect(config.resolvers.single.port, 5300);
    expect(config.chatBytes, 64);
    expect(config.selectBudget, const Duration(seconds: 90));
    expect(config.carryBudget, const Duration(seconds: 150));
    expect(config.relayOnly, isTrue, reason: 'ICE is forced relay-only');
    expect(config.totalBudget, const Duration(seconds: 240));
    expect(config.toJson()['resolvers'], <String>['192.168.2.1:5300']);
  });

  test('a dns_valve value that is not a map is ignored, never a crash', () {
    final job = JourneyJob.tryParse(
      '{"run":"r1","key":"k1","hold_s":400,"dns_valve":"yes"}',
    )!;
    expect(job.dnsValve, isNull);
  });

  test('dns_valve defaults fill in, and relay_only stays off', () {
    final config = DnsValveConfig.parse(const <String, Object?>{
      'zone': 'valve.example',
    });
    expect(config.resolvers, isEmpty, reason: 'the device walks its own');
    expect(config.chatBytes, 64);
    expect(config.selectBudget, const Duration(seconds: 120));
    expect(config.carryBudget, const Duration(seconds: 120));
    expect(config.relayOnly, isFalse);
  });

  test('a dns_valve map that cannot produce a row is rejected at arm time', () {
    // No zone: the lane has nothing to query.
    expect(
      () => DnsValveConfig.parse(const <String, Object?>{'chat_bytes': 64}),
      throwsA(isA<FormatException>()),
    );
    // A message longer than the lane's own limit is refused as transient by
    // the valve, so the fabric would carry it on a WAN lane and the row
    // would read `carried_without_selection` for a config reason.
    expect(
      () => DnsValveConfig.parse(const <String, Object?>{
        'zone': 'valve.example',
        'chat_bytes': 5000,
      }),
      throwsA(isA<FormatException>()),
    );
    // A resolver that is not host:port is a runner bug, never dropped.
    expect(
      () => DnsValveConfig.parse(const <String, Object?>{
        'zone': 'valve.example',
        'resolvers': <String>['192.168.2.1'],
      }),
      throwsA(isA<FormatException>()),
    );
    for (final field in const ['chat_bytes', 'select_budget_s']) {
      expect(
        () => DnsValveConfig.parse(<String, Object?>{
          'zone': 'valve.example',
          field: 0,
        }),
        throwsA(isA<FormatException>()),
        reason: field,
      );
    }
  });

  test(
    'the carried payload is exactly chat_bytes and derived from the run',
    () {
      final first = dnsValvePayload('r2', 64);
      expect(first.length, 64);
      expect(
        dnsValvePayload('r2', 64),
        first,
        reason: 'the Mac recomputes it from the run id it handed out',
      );
      expect(
        dnsValvePayload('r3', 64),
        isNot(first),
        reason: 'a stale run cannot satisfy another run sha256',
      );
      expect(dnsValvePayload('r2', 1).length, 1);
    },
  );
}
