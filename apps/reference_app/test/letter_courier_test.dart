// The courier's verdicts without a network: every lane aimed at a closed
// loopback port, so the policy's tail (door down → parked in the queue)
// and its refusals are decided here, deterministically. The "arrived
// through the door" case needs a responder and is the rig's row.
import 'dart:typed_data';

import 'package:adaptive_transport/adaptive_transport.dart'
    show HostPort, TxtQueryLane, TxtQueryValve;
import 'package:connection_orchestrator/connection_orchestrator.dart'
    show ResilientLaneEndpoints;
import 'package:flutter_test/flutter_test.dart';
import 'package:reference_app/src/letter_composer.dart';
import 'package:reference_app/src/letter_courier.dart';

const fast = LetterCourierBudget(
  select: Duration(milliseconds: 300),
  carry: Duration(seconds: 15),
  refreshEvery: Duration(milliseconds: 50),
);

/// Nothing listens on 127.0.0.1:9 (discard, never bound here): the relay
/// connect is refused at once and the valve's one probe fails.
ResilientLaneEndpoints deadLanes({bool door = true}) => ResilientLaneEndpoints(
  relayUri: Uri.parse('wss://127.0.0.1:9/'),
  longPollUri: Uri.parse('https://127.0.0.1:9/poll'),
  txtQueryValve: door
      ? const TxtQueryValve(
          domain: 'valve.test',
          resolvers: [HostPort(host: '127.0.0.1', port: 9)],
        )
      : null,
);

void main() {
  test(
    'a letter over the door limit is refused before any lane is touched',
    () async {
      final courier = LetterCourier(
        endpoints: () => throw StateError('lanes must not be built'),
        budget: fast,
      );
      final state = await courier.send(
        Uint8List(TxtQueryLane.maxPayloadBytes + 1),
        kind: 'typed',
      );
      expect(state, LetterState.notDelivered);
      expect(courier.status.value!.detail, contains('too long'));
      expect(
        courier.status.value!.detail,
        contains('${TxtQueryLane.maxPayloadBytes}'),
      );
      await courier.dispose();
    },
  );

  test('a build with no lane at all says so instead of waiting', () async {
    final courier = LetterCourier(
      endpoints: () => const ResilientLaneEndpoints(),
      budget: fast,
    );
    await courier.probe();
    expect(courier.status.value!.state, LetterState.notDelivered);
    expect(courier.status.value!.detail, contains('no lane configured'));
    final state = await courier.send(
      Uint8List.fromList([1, 2, 3]),
      kind: 'typed',
    );
    expect(state, LetterState.notDelivered);
    await courier.dispose();
  });

  test(
    'every lane dead: live call unavailable, then queued as parked — never a spinner',
    () async {
      final courier = LetterCourier(
        endpoints: deadLanes,
        budget: fast,
        // One failed probe marks the door down, so the verdict is the
        // queue's and not a 10 s per-chunk wait.
        valveFailThreshold: 1,
      );
      final seen = <LetterState>[];
      courier.status.addListener(() {
        final s = courier.status.value;
        if (s != null) seen.add(s.state);
      });
      await courier.probe();
      expect(courier.status.value!.state, LetterState.liveCallUnavailable);

      final state = await courier.send(
        Uint8List.fromList('hello through the door'.codeUnits),
        kind: 'typed',
      );
      expect(state, LetterState.queued, reason: courier.notes.value.join('\n'));
      expect(courier.status.value!.detail, contains('parked'));
      expect(seen, contains(LetterState.liveCallUnavailable));
      expect(seen.last, LetterState.queued);
      expect(courier.busy.value, isFalse);
      await courier.dispose();
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'a second Send while one is in flight is ignored, not stacked',
    () async {
      final courier = LetterCourier(
        endpoints: deadLanes,
        budget: fast,
        valveFailThreshold: 1,
      );
      final first = courier.send(Uint8List.fromList([1]), kind: 'typed');
      final second = await courier.send(Uint8List.fromList([2]), kind: 'typed');
      expect(second, LetterState.queued); // the state of the letter in flight
      await first;
      expect(courier.busy.value, isFalse);
      await courier.dispose();
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
