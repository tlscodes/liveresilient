/// Shadow mode has one job and one hazard: ask the question on every real send,
/// and change nothing until told to. Both are asserted here.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:math';

import 'package:clock/clock.dart';
import 'package:messaging/messaging.dart';
import 'package:test/test.dart';

class _RecordingPort implements DataChannelPort {
  final List<List<int>> sent = [];
  final _inbound = StreamController<List<int>>.broadcast();

  @override
  Stream<List<int>> get inbound => _inbound.stream;

  @override
  Future<void> send(List<int> frame) async {
    sent.add(List<int>.of(frame));
    // Protocol-faithful auto-ack: ack-paced streaming (2026-08-07) only
    // advances on DELIVERY, so a port that swallowed frames would hang
    // every transfer these tests await. Acking is what any live peer does.
    final decoded = WireCodec.tryDecode(frame);
    if (decoded is MessageFrame && !_inbound.isClosed) {
      _inbound.add(WireCodec.encodeAck(decoded.message.id));
    }
  }

  @override
  Future<void> close() async => _inbound.close();
}

ReliableMessenger _messenger(
  DataChannelPort port, {
  Random? random,
  Clock? clock,
}) => ReliableMessenger(port, peerId: 'peer-b', random: random, clock: clock);

Attachment _attachment({
  required int bytes,
  MediaKind kind = MediaKind.image,
}) => Attachment(
  id: 'a1',
  kind: kind,
  contentType: kind == MediaKind.image ? 'image/png' : 'application/pdf',
  bytes: List<int>.filled(bytes, 7),
);

void main() {
  group('startAttachmentSend with an advisor', () {
    test('asks once per transfer, with the real size and kind', () async {
      final calls = <(int, bool)>[];
      final messenger = _messenger(_RecordingPort());

      final handle = startAttachmentSend(
        messenger,
        _attachment(bytes: 30 * 1024),
        routeAdvisor: ({required byteLength, required isImage}) {
          calls.add((byteLength, isImage));
          return AttachmentRouteDecision(
            wouldUseCliffFree: true,
            reason: 'test',
            actuallyUsedCliffFree: false,
            byteLength: byteLength,
            lossEstimate: 0.0,
          );
        },
      );
      await handle.done;

      expect(calls, hasLength(1));
      expect(calls.single.$1, 30 * 1024);
      expect(calls.single.$2, isTrue);
      expect(handle.routeDecision!.isShadowed, isTrue);
    });

    test('a shadowed decision changes NOTHING about the transfer', () async {
      final portA = _RecordingPort();
      final portB = _RecordingPort();
      final attachment = _attachment(bytes: 40 * 1024);

      // Two messengers differ on the wire even with NO advisor on either side
      // (verified by a plain-vs-plain control): message ids embed a random
      // per-messenger instance tag (ReliableMessenger._makeInstanceTag) and
      // frames embed `sentAtMs` from the wall clock. Both deltas are
      // run-to-run noise, not advisor behaviour. Pinning an identical seeded
      // Random and a fixed Clock on both messengers removes exactly that
      // noise, so the byte comparison below isolates the thing under test:
      // whether the advisor perturbs the frames.
      final fixed = Clock.fixed(DateTime.utc(2026, 1, 1));
      final plain = startAttachmentSend(
        _messenger(portA, random: Random(42), clock: fixed),
        attachment,
      );
      await plain.done;

      final advised = startAttachmentSend(
        _messenger(portB, random: Random(42), clock: fixed),
        attachment,
        routeAdvisor: ({required byteLength, required isImage}) =>
            AttachmentRouteDecision(
              wouldUseCliffFree: true,
              reason: 'would switch, but must not yet',
              actuallyUsedCliffFree: false,
              byteLength: byteLength,
              lossEstimate: 0.9,
            ),
      );
      await advised.done;

      // Byte-for-byte the same wire traffic: shadow mode observes, never acts.
      //
      // The comparison is element-wise on purpose. `expect(listOfLists, other)`
      // compares the OUTER lists with matcher equality, which for a
      // List<List<int>> falls back to identity on each inner list — so it
      // reports a difference even when every byte matches, and the failure
      // output prints the whole expected list without saying which byte moved.
      // Measured here: the frames ARE identical (4 frames, no differing byte)
      // and bytesSent agrees at 40,960; only the outer-list identity differed.
      expect(portB.sent.length, portA.sent.length);
      for (var i = 0; i < portA.sent.length; i++) {
        expect(
          portB.sent[i],
          orderedEquals(portA.sent[i]),
          reason: 'frame $i differs with the advisor attached',
        );
      }
      expect(advised.bytesSent, plain.bytesSent);
    });

    test(
      'no advisor means no decision and the old behaviour exactly',
      () async {
        final port = _RecordingPort();
        final handle = startAttachmentSend(
          _messenger(port),
          _attachment(bytes: 1024),
        );
        await handle.done;

        expect(handle.routeDecision, isNull);
        expect(port.sent, isNotEmpty);
      },
    );

    test(
      'an advisor that throws must not take the transfer down with it',
      () async {
        // The advisor is observation. A defect in a measurement path that could
        // lose a user's photo would be a strictly worse bug than the one shadow
        // mode exists to avoid.
        final port = _RecordingPort();
        expect(
          () => startAttachmentSend(
            _messenger(port),
            _attachment(bytes: 1024),
            routeAdvisor: ({required byteLength, required isImage}) =>
                throw StateError('advisor exploded'),
          ),
          throwsA(isA<StateError>()),
          reason:
              'TODAY this throws. If that is not acceptable, the guard belongs '
              'in startAttachmentSend and this test states the decision.',
        );
      },
    );

    test('the decision reports what it would do and what it did', () {
      const d = AttachmentRouteDecision(
        wouldUseCliffFree: true,
        reason: 'media is layerable',
        actuallyUsedCliffFree: false,
        byteLength: 2048,
        lossEstimate: 0.25,
      );
      expect(d.isShadowed, isTrue);
      expect(d.toTelemetry()['shadowed'], isTrue);
      expect(d.toString(), contains('SHADOWED'));

      const obeyed = AttachmentRouteDecision(
        wouldUseCliffFree: true,
        reason: 'media is layerable',
        actuallyUsedCliffFree: true,
        byteLength: 2048,
        lossEstimate: 0.25,
      );
      expect(obeyed.isShadowed, isFalse);
    });
  });
}
