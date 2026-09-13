// The TXT query lane, on the phone, against a responder on the rig Mac.
//
// The lane's unit suites run an in-process responder on the Mac; this file
// runs the same Dart lane on iOS, where there is no resolv.conf, no Python,
// and the socket is the phone's own. The responder is
// tools/t2/txt_query_server.py bound to the Mac's bridge100 address.
//
//   python3 tools/t2/txt_query_server.py --domain valve.test \
//       --host 192.168.2.1 --port 5300
//   flutter test integration_test/txt_query_lane_on_device_test.dart \
//       -d <udid> --dart-define=VALVE_HOST=192.168.2.1 \
//       --dart-define=VALVE_PORT=5300
//
// Each case pins one of the 2026-09-12 review fixes where the phone can
// exercise it (rotation charged once, a refused zone is a result not a
// throw); the DoH body cap and the byte-wise source filter need a hostile
// endpoint the rig does not have and stay covered by the unit suites.
//
// Under the retry policy a budgeted case can legitimately run past the
// `test` package's 30 s default under heavy loss (up to 24 paced attempts
// per chunk), so the whole file carries a wider timeout.
@Timeout(Duration(minutes: 6))
library;

import 'package:adaptive_transport/adaptive_transport.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const String _host = String.fromEnvironment('VALVE_HOST');
const int _port = int.fromEnvironment('VALVE_PORT', defaultValue: 5300);
const String _domain = String.fromEnvironment(
  'VALVE_DOMAIN',
  defaultValue: 'valve.test',
);

/// Set by tools/t2/txt_lane_phone_matrix.sh while bridge100 is shaped: the
/// timing bounds widen to the shaper's worst case and every measured case
/// prints a `TXTLANE` line the matrix turns into a TSV row. Delivery is
/// still asserted where the profile allows it; under loss the delivery-rate
/// case records numbers instead of asserting them.
const bool _shaped = bool.fromEnvironment('VALVE_SHAPED');

/// One round trip on the rig: ~1 ms clean; up to ~2.5 s under the extreme
/// profile (1000 ms delay each way at 16 kbit/s), and a multi-chunk send is
/// several of them.
const int _rttBoundMs = _shaped ? 15000 : 1000;

/// The matrix's data channel: one line per measurement, greppable.
void _report(String line) {
  // ignore: avoid_print
  print('TXTLANE $line');
}

/// The app's own policy by default (TxtQueryLane.forValve: a 24-attempt
/// cap under the derived chunk budget); the strict policy (1) is asked for
/// explicitly where a case wants the "before" number.
TxtQueryLane _laneOver(
  List<TxtQueryTransport> transports, {
  int attemptsPerChunk = 24,
  int failThreshold = 5,
}) => TxtQueryLane(
  domain: _domain,
  transports: transports,
  timeout: const Duration(seconds: 3),
  attemptsPerChunk: attemptsPerChunk,
  failThreshold: failThreshold,
);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final live = HostPort(host: _host, port: _port);
  // Nothing listens on the two ports above the responder's.
  final dead1 = HostPort(host: _host, port: _port + 1);
  final dead2 = HostPort(host: _host, port: _port + 2);

  setUpAll(() async {
    expect(_host, isNotEmpty, reason: 'pass --dart-define=VALVE_HOST=<mac ip>');
    _report('shaped=$_shaped host=$_host port=$_port zone=$_domain');
    // The matrix applies the shaper only once this line has appeared — at
    // 60 % loss the launch handshake itself did not complete (2026-09-13) —
    // and asks the cases to hold while the shaping lands.
    const settleMs = int.fromEnvironment('VALVE_SETTLE_MS');
    if (settleMs > 0) {
      await Future<void>.delayed(const Duration(milliseconds: settleMs));
    }
  });

  test(
    'the phone reaches the responder: probe, one chunk, many chunks',
    () async {
      final lane = _laneOver(<TxtQueryTransport>[Udp53QueryTransport(live)]);
      addTearDown(lane.dispose);

      final probed = await lane.probe();
      final one = await lane.send(List<int>.generate(20, (i) => i));
      final many = await lane.send(
        List<int>.generate(120, (i) => (i * 7) & 0xff),
      );
      _report(
        'case=echo probe=$probed one=${one.status.name}/${one.rttMs}ms '
        'many=${many.status.name}/${many.rttMs}ms attempts=${lane.attempts} '
        'replies=${lane.replies}',
      );

      expect(probed, isTrue, reason: 'empty payload is one query');
      expect(one.status, SendStatus.ok, reason: '${one.error}');
      expect(one.rttMs, lessThan(_rttBoundMs), reason: 'bridge100 round trip');
      expect(many.status, SendStatus.ok, reason: '${many.error}');
      expect(many.rttMs, lessThan(_rttBoundMs));

      expect(lane.isDown, isFalse);
      expect(lane.health.pathDegraded, isFalse);
      expect(lane.health.availability, 1.0);
      // health.rttMs is an EMA seeded at 9999 ms (ChannelHealth default);
      // three ~1 ms samples only pull it to ~3.4 s. Measured on the phone
      // 2026-09-12: 3444. The per-send samples above are the link; this only
      // checks the tracker moved off its prior.
      expect(lane.health.rttMs, lessThan(9999));
    },
  );

  test('the app\'s own construction path works on iOS: forValve with pinned '
      'resolvers (no resolv.conf on the phone)', () async {
    final lane = TxtQueryLane.forValve(
      TxtQueryValve(domain: _domain, resolvers: <HostPort>[live]),
    );
    addTearDown(lane.dispose);
    final r = await lane.send(<int>[1, 2, 3, 4, 5]);
    expect(r.status, SendStatus.ok, reason: '${r.error}');
  });

  test('rotating through dead resolvers on one send is ONE failure, '
      'so a brief outage cannot declare the valve DOWN (review #5)', () async {
    // failThreshold 2 with two dead candidates ahead of the live one: before
    // the fix each rotation was a failure, so this send would have gone
    // DOWN before it ever reached the responder.
    final lane = TxtQueryLane(
      domain: _domain,
      transports: <TxtQueryTransport>[
        Udp53QueryTransport(dead1),
        Udp53QueryTransport(dead2),
        Udp53QueryTransport(live),
      ],
      timeout: const Duration(seconds: 2),
      failThreshold: 2,
      // The app's policy: on a dead transport the chunk budget, not the
      // count, is what ends the attempts before rotating.
      attemptsPerChunk: 24,
    );
    addTearDown(lane.dispose);

    final sw = Stopwatch()..start();
    final r = await lane.send(List<int>.generate(30, (i) => i + 1));
    sw.stop();
    expect(r.status, SendStatus.ok, reason: '${r.error}');
    expect(lane.isDown, isFalse);
    expect(lane.health.pathDegraded, isFalse);
    expect(
      sw.elapsed,
      greaterThanOrEqualTo(const Duration(seconds: 4)),
      reason: 'two 2 s timeouts precede the live transport',
    );

    // The lane stays on the transport that answered.
    final again = await lane.send(<int>[9, 9, 9]);
    expect(again.status, SendStatus.ok);
    expect(again.rttMs, lessThan(_rttBoundMs));
  });

  test('delivery rate over five 100-byte sends: strict policy vs retry '
      'policy (attemptsPerChunk 1 vs 3)', () async {
    // Five sequential sends of three chunks each, per policy. Clean link:
    // both must deliver 5/5. Shaped link: the numbers are the evidence —
    // at 60 % i.i.d. loss even the retry policy is expected to lose most
    // three-chunk payloads, and the row says so rather than pretending.
    Future<int> rate(int attemptsPerChunk) async {
      final lane = _laneOver(<TxtQueryTransport>[
        Udp53QueryTransport(live),
      ], attemptsPerChunk: attemptsPerChunk);
      var delivered = 0;
      final sw = Stopwatch()..start();
      for (var i = 0; i < 5; i++) {
        final r = await lane.send(
          List<int>.generate(100, (j) => (i * 31 + j) & 0xff),
        );
        if (r.status == SendStatus.ok) delivered += 1;
      }
      sw.stop();
      _report(
        'case=rate policy=${attemptsPerChunk == 1 ? "strict" : "retry"} '
        'attemptsPerChunk=$attemptsPerChunk delivered=$delivered/5 '
        'ms=${sw.elapsedMilliseconds} attempts=${lane.attempts} '
        'replies=${lane.replies} down=${lane.isDown}',
      );
      await lane.dispose();
      return delivered;
    }

    final strict = await rate(1);
    final retry = await rate(24);
    if (!_shaped) {
      expect(strict, 5);
      expect(retry, 5);
    }
  }, timeout: const Timeout(Duration(minutes: 6)));

  test('a zone the wire layer refuses is a transient result, not a throw '
      '(review #7)', () async {
    final lane = TxtQueryLane(
      domain: '${'a' * 70}.$_domain',
      transports: <TxtQueryTransport>[Udp53QueryTransport(live)],
      timeout: const Duration(seconds: 2),
    );
    addTearDown(lane.dispose);
    final r = await lane.send(<int>[1, 2, 3]);
    expect(r.status, SendStatus.transient);
    expect(r.error, isA<TxtQueryWireException>());
    expect(await lane.probe(), isFalse);
    expect(
      lane.isDown,
      isFalse,
      reason: 'a refusal says nothing about the path',
    );
  });

  test('the phone default (public resolvers, no zone answering) fails as '
      'one charged failure and the valve stays UP', () async {
    // This is the shape of a real outage: the phone discovers no system
    // resolver, tries the public ones in turn, none answers for the zone.
    final lane = TxtQueryLane.forValve(TxtQueryValve(domain: _domain));
    addTearDown(lane.dispose);
    final r = await lane.send(<int>[1, 2, 3]);
    expect(r.status, isNot(SendStatus.ok));
    expect(
      lane.isDown,
      isFalse,
      reason: 'one send that exhausts every candidate is one failure',
    );
  }, timeout: const Timeout(Duration(seconds: 90)));
}
