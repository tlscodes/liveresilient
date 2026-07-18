import 'dart:math';
import 'dart:typed_data';

import 'package:device_link/device_link.dart';
import 'package:test/test.dart';

class _FakeAuthenticator implements MediaFrameAuthenticator {
  @override
  Future<bool> verify(MediaFrame envelope) async => true;

  @override
  Future<MediaFrame> createForwardedEnvelope(MediaFrame envelope) async {
    return MediaFrame(
      version: envelope.version,
      messageId: envelope.messageId,
      originKeyId: envelope.originKeyId,
      currentRelayKeyId: 'relay-forwarded',
      createdAtMs: envelope.createdAtMs,
      expiresAtMs: envelope.expiresAtMs,
      maxHops: envelope.maxHops,
      hopCount: envelope.hopCount + 1,
      ciphertext: envelope.ciphertext,
      signature: envelope.signature,
    );
  }
}

class _FakeBroadcaster implements MeshBroadcaster {
  final List<MediaFrame> broadcasted = [];

  @override
  Future<void> broadcast(MediaFrame envelope) async {
    broadcasted.add(envelope);
  }
}

MediaFrame _frame({
  required String messageId,
  int createdAtMs = 1000000,
  int? expiresAtMs,
}) {
  return MediaFrame(
    messageId: messageId,
    originKeyId: 'origin-a',
    currentRelayKeyId: 'relay-a',
    createdAtMs: createdAtMs,
    expiresAtMs: expiresAtMs ?? createdAtMs + 60000,
    maxHops: 3,
    hopCount: 0,
    ciphertext: Uint8List.fromList([1, 2, 3]),
    signature: Uint8List.fromList([9, 9, 9]),
  );
}

void main() {
  const nowMs = 1000000;

  late _FakeBroadcaster broadcaster;
  late List<MediaFrame> delivered;

  MeshMessageProcessor innerProcessor() {
    broadcaster = _FakeBroadcaster();
    delivered = [];
    return MeshMessageProcessor(
      authenticator: _FakeAuthenticator(),
      broadcaster: broadcaster,
      seenCache: MeshSeenCache(),
      onDeliver: (envelope) async => delivered.add(envelope),
    );
  }

  GuardedMeshProcessor guarded(MeshFlowControlConfig config) {
    return GuardedMeshProcessor(inner: innerProcessor(), config: config);
  }

  group('MeshFlowControlConfig', () {
    test('rejects out-of-range knobs at construction', () {
      const badConfigs = [
        MeshFlowControlConfig(perPeerWindowMs: 0),
        MeshFlowControlConfig(maxMessagesPerPeerPerWindow: 0),
        MeshFlowControlConfig(maxGlobalMessagesPerSecond: 0),
        MeshFlowControlConfig(burstAllowance: -1),
        MeshFlowControlConfig(maxTrackedPeers: 0),
        MeshFlowControlConfig(priorityReserveFraction: 0.6),
        MeshFlowControlConfig(priorityReserveFraction: -0.1),
      ];

      for (final config in badConfigs) {
        expect(
          () => GuardedMeshProcessor(inner: innerProcessor(), config: config),
          throwsArgumentError,
        );
      }
    });

    test('defaults are valid', () {
      expect(
        guarded(const MeshFlowControlConfig()),
        isA<GuardedMeshProcessor>(),
      );
    });
  });

  group('per-peer quota', () {
    test('caps admissions per peer inside the sliding window', () async {
      final processor = guarded(
        const MeshFlowControlConfig(
          perPeerWindowMs: 10000,
          maxMessagesPerPeerPerWindow: 3,
          maxGlobalMessagesPerSecond: 1000,
        ),
      );

      for (var i = 0; i < 3; i++) {
        final outcome = await processor.process(
          _frame(messageId: 'peer-a-msg-$i'),
          peerId: 'peer-a',
          priority: MeshMessagePriority.presence,
          nowMs: nowMs + i,
        );
        expect(outcome.disposition, MeshDisposition.delivered);
      }

      final overQuota = await processor.process(
        _frame(messageId: 'peer-a-msg-3'),
        peerId: 'peer-a',
        priority: MeshMessagePriority.presence,
        nowMs: nowMs + 3,
      );
      expect(overQuota.rejection, MeshFlowRejection.peerQuotaExceeded);

      // Other peers are unaffected by peer-a's quota.
      final otherPeer = await processor.process(
        _frame(messageId: 'peer-b-msg-0'),
        peerId: 'peer-b',
        priority: MeshMessagePriority.presence,
        nowMs: nowMs + 3,
      );
      expect(otherPeer.disposition, MeshDisposition.delivered);
    });

    test(
      'window slides: the peer is admitted again after it elapses',
      () async {
        final processor = guarded(
          const MeshFlowControlConfig(
            perPeerWindowMs: 10000,
            maxMessagesPerPeerPerWindow: 1,
            maxGlobalMessagesPerSecond: 1000,
          ),
        );

        expect(
          (await processor.process(
            _frame(messageId: 'm-0'),
            peerId: 'peer-a',
            priority: MeshMessagePriority.bulk,
            nowMs: nowMs,
          )).admitted,
          isTrue,
        );
        expect(
          (await processor.process(
            _frame(messageId: 'm-1'),
            peerId: 'peer-a',
            priority: MeshMessagePriority.bulk,
            nowMs: nowMs + 5000,
          )).rejection,
          MeshFlowRejection.peerQuotaExceeded,
        );
        expect(
          (await processor.process(
            _frame(messageId: 'm-2'),
            peerId: 'peer-a',
            priority: MeshMessagePriority.bulk,
            nowMs: nowMs + 10001,
          )).admitted,
          isTrue,
        );
      },
    );
  });

  group('rate limit and priority shedding', () {
    // capacity 10, reserve 0.2 → thresholds: callSignal 1, presence 3, bulk 5.
    const config = MeshFlowControlConfig(
      maxGlobalMessagesPerSecond: 10,
      burstAllowance: 0,
      maxMessagesPerPeerPerWindow: 1000,
      priorityReserveFraction: 0.2,
    );

    Future<GuardedMeshOutcome> send(
      GuardedMeshProcessor processor,
      int index,
      MeshMessagePriority priority,
    ) {
      return processor.process(
        _frame(messageId: 'msg-$index'),
        peerId: 'peer-$index',
        priority: priority,
        nowMs: nowMs,
      );
    }

    test(
      'drops lowest priority first as the bucket drains — deterministic',
      () async {
        final processor = guarded(config);
        var index = 0;

        // Bulk admitted while tokens >= 5 (10..5 → six sends).
        for (var i = 0; i < 6; i++) {
          expect(
            (await send(processor, index++, MeshMessagePriority.bulk)).admitted,
            isTrue,
          );
        }
        expect(
          (await send(processor, index++, MeshMessagePriority.bulk)).rejection,
          MeshFlowRejection.rateLimited,
        );

        // Presence still passes until tokens fall below 3.
        for (var i = 0; i < 2; i++) {
          expect(
            (await send(
              processor,
              index++,
              MeshMessagePriority.presence,
            )).admitted,
            isTrue,
          );
        }
        expect(
          (await send(
            processor,
            index++,
            MeshMessagePriority.presence,
          )).rejection,
          MeshFlowRejection.rateLimited,
        );

        // Call signaling drains the bucket to zero.
        for (var i = 0; i < 2; i++) {
          expect(
            (await send(
              processor,
              index++,
              MeshMessagePriority.callSignal,
            )).admitted,
            isTrue,
          );
        }
        expect(
          (await send(
            processor,
            index++,
            MeshMessagePriority.callSignal,
          )).rejection,
          MeshFlowRejection.rateLimited,
        );
      },
    );

    test('tokens refill over elapsed fake time', () async {
      final processor = guarded(config);

      for (var i = 0; i < 10; i++) {
        await processor.process(
          _frame(messageId: 'drain-$i'),
          peerId: 'peer-drain-$i',
          priority: MeshMessagePriority.callSignal,
          nowMs: nowMs,
        );
      }
      expect(
        (await processor.process(
          _frame(messageId: 'blocked'),
          peerId: 'peer-x',
          priority: MeshMessagePriority.callSignal,
          nowMs: nowMs,
        )).rejection,
        MeshFlowRejection.rateLimited,
      );

      // 500ms at 10 msg/s mints 5 tokens.
      expect(
        (await processor.process(
          _frame(messageId: 'refilled'),
          peerId: 'peer-x',
          priority: MeshMessagePriority.callSignal,
          nowMs: nowMs + 500,
        )).admitted,
        isTrue,
      );
    });

    test('a clock reading that rewinds never mints tokens', () async {
      final processor = guarded(config);

      for (var i = 0; i < 10; i++) {
        await send(processor, i, MeshMessagePriority.callSignal);
      }
      expect(
        (await processor.process(
          _frame(messageId: 'rewind', createdAtMs: nowMs - 5000),
          peerId: 'peer-x',
          priority: MeshMessagePriority.callSignal,
          nowMs: nowMs - 1000,
        )).rejection,
        MeshFlowRejection.rateLimited,
      );
    });
  });

  group('inner processor semantics preserved through the guard', () {
    late GuardedMeshProcessor processor;

    setUp(() {
      processor = guarded(
        const MeshFlowControlConfig(maxGlobalMessagesPerSecond: 1000),
      );
    });

    test('TTL is still enforced on admitted messages', () async {
      final outcome = await processor.process(
        _frame(
          messageId: 'stale',
          createdAtMs: nowMs - 60000,
          expiresAtMs: nowMs,
        ),
        peerId: 'peer-a',
        priority: MeshMessagePriority.callSignal,
        nowMs: nowMs,
      );
      expect(outcome.disposition, MeshDisposition.expired);
      expect(delivered, isEmpty);
    });

    test('duplicate suppression is intact', () async {
      final frame = _frame(messageId: 'dup-1');

      final first = await processor.process(
        frame,
        peerId: 'peer-a',
        priority: MeshMessagePriority.callSignal,
        nowMs: nowMs,
      );
      final second = await processor.process(
        frame,
        peerId: 'peer-b',
        priority: MeshMessagePriority.callSignal,
        nowMs: nowMs + 1,
      );

      expect(first.disposition, MeshDisposition.delivered);
      expect(second.disposition, MeshDisposition.duplicate);
      expect(delivered, hasLength(1));
    });

    test('forwarding kill-switch stays off by default', () async {
      final outcome = await processor.process(
        _frame(messageId: 'no-forward'),
        peerId: 'peer-a',
        priority: MeshMessagePriority.callSignal,
        nowMs: nowMs,
      );
      expect(outcome.disposition, MeshDisposition.delivered);
      expect(broadcaster.broadcasted, isEmpty);
    });

    test('empty peerId is a programming error, not a silent pass', () {
      expect(
        () => processor.process(
          _frame(messageId: 'no-peer'),
          peerId: '',
          priority: MeshMessagePriority.bulk,
          nowMs: nowMs,
        ),
        throwsArgumentError,
      );
    });
  });

  group('simulated multi-peer load (seeded, fake clock)', () {
    Future<({GuardedMeshProcessor processor, _SimulationTally tally})>
    runSimulation({
      required int peerCount,
      required int messagesPerPeer,
      required MeshFlowControlConfig config,
      required int seed,
      int spanMs = 2000,
      int duplicateEvery = 0,
      int expiredEvery = 0,
    }) async {
      final random = Random(seed);
      final processor = guarded(config);

      final events =
          <
            ({
              int atMs,
              String peerId,
              MeshMessagePriority priority,
              MediaFrame frame,
            })
          >[];
      var sequence = 0;
      for (var p = 0; p < peerCount; p++) {
        for (var m = 0; m < messagesPerPeer; m++) {
          final atMs = nowMs + random.nextInt(spanMs);
          final priority = MeshMessagePriority
              .values[random.nextInt(MeshMessagePriority.values.length)];
          final isDuplicate =
              duplicateEvery > 0 &&
              sequence > 0 &&
              sequence % duplicateEvery == 0;
          final isExpired =
              expiredEvery > 0 && sequence > 0 && sequence % expiredEvery == 0;
          events.add((
            atMs: atMs,
            peerId: 'peer-$p',
            priority: priority,
            frame: _frame(
              messageId: isExpired
                  ? 'sim-expired-$sequence'
                  : (isDuplicate ? 'sim-msg-0' : 'sim-msg-$sequence'),
              createdAtMs: isExpired ? atMs - 30000 : atMs,
              expiresAtMs: isExpired ? atMs : null,
            ),
          ));
          sequence++;
        }
      }
      events.sort((a, b) => a.atMs.compareTo(b.atMs));

      final tally = _SimulationTally();
      for (final event in events) {
        tally.sentByPriority.update(event.priority, (count) => count + 1);

        final outcome = await processor.process(
          event.frame,
          peerId: event.peerId,
          priority: event.priority,
          nowMs: event.atMs,
        );

        switch (outcome.rejection) {
          case MeshFlowRejection.peerQuotaExceeded:
            tally.quotaShed++;
          case MeshFlowRejection.rateLimited:
            tally.rateShed++;
          case null:
            switch (outcome.disposition!) {
              case MeshDisposition.delivered:
              case MeshDisposition.deliveredAndForwarded:
                tally.admittedByPriority.update(
                  event.priority,
                  (count) => count + 1,
                );
                tally.deliveredByPeer.update(
                  event.peerId,
                  (count) => count + 1,
                  ifAbsent: () => 1,
                );
                tally.deliveredFrames.add(event.frame);
              case MeshDisposition.duplicate:
                tally.duplicates++;
              case MeshDisposition.expired:
                tally.expired++;
              case MeshDisposition.invalid:
              case MeshDisposition.hopLimitReached:
              case MeshDisposition.rejected:
                tally.other++;
            }
        }
      }
      return (processor: processor, tally: tally);
    }

    test('5 peers under light load: everything is delivered', () async {
      final tally = (await runSimulation(
        peerCount: 5,
        messagesPerPeer: 4,
        seed: 11,
        config: const MeshFlowControlConfig(
          maxMessagesPerPeerPerWindow: 10,
          maxGlobalMessagesPerSecond: 100,
          burstAllowance: 50,
        ),
      )).tally;

      expect(tally.quotaShed, 0);
      expect(tally.rateShed, 0);
      expect(tally.deliveredByPeer.values.reduce((a, b) => a + b), 20);
    });

    test('10 peers: per-peer quota holds under a hammering burst', () async {
      const config = MeshFlowControlConfig(
        perPeerWindowMs: 10000,
        maxMessagesPerPeerPerWindow: 5,
        maxGlobalMessagesPerSecond: 1000,
        burstAllowance: 1000,
      );
      final tally = (await runSimulation(
        peerCount: 10,
        messagesPerPeer: 12,
        seed: 23,
        spanMs: 1000, // whole burst inside one quota window
        config: config,
      )).tally;

      for (final entry in tally.deliveredByPeer.entries) {
        expect(
          entry.value,
          lessThanOrEqualTo(config.maxMessagesPerPeerPerWindow),
          reason: '${entry.key} exceeded its per-window quota',
        );
      }
      expect(tally.quotaShed, greaterThan(0));
    });

    test('20 peers over capacity: priorities shed lowest-first, TTL and '
        'duplicate suppression stay intact', () async {
      final (:processor, :tally) = await runSimulation(
        peerCount: 20,
        messagesPerPeer: 10,
        seed: 42,
        duplicateEvery: 25,
        expiredEvery: 40,
        config: const MeshFlowControlConfig(
          perPeerWindowMs: 10000,
          maxMessagesPerPeerPerWindow: 3,
          maxGlobalMessagesPerSecond: 20,
          burstAllowance: 10,
          priorityReserveFraction: 0.2,
        ),
      );

      double admittedFraction(MeshMessagePriority priority) {
        final sent = tally.sentByPriority[priority]!;
        return sent == 0 ? 1 : tally.admittedByPriority[priority]! / sent;
      }

      // Overload is real: both shedding mechanisms engaged.
      expect(tally.rateShed, greaterThan(0));
      expect(tally.quotaShed, greaterThan(0));

      // Lowest priority is shed first: admission rate is ordered.
      expect(
        admittedFraction(MeshMessagePriority.callSignal),
        greaterThanOrEqualTo(admittedFraction(MeshMessagePriority.presence)),
      );
      expect(
        admittedFraction(MeshMessagePriority.presence),
        greaterThanOrEqualTo(admittedFraction(MeshMessagePriority.bulk)),
      );

      // Invariants under load: no expired frame was ever delivered, and the
      // duplicated message id was delivered at most once.
      expect(
        tally.deliveredFrames.where(
          (frame) => frame.messageId.startsWith('sim-expired-'),
        ),
        isEmpty,
      );
      expect(
        tally.deliveredFrames
            .where((frame) => frame.messageId == 'sim-msg-0')
            .length,
        lessThanOrEqualTo(1),
      );
      expect(tally.other, 0);

      // Deterministic probes after the bucket refills and a fresh quota
      // window opens: TTL rejection and duplicate suppression still work.
      final probeAtMs = nowMs + 20000;
      final expiredProbe = await processor.process(
        _frame(
          messageId: 'probe-expired',
          createdAtMs: probeAtMs - 30000,
          expiresAtMs: probeAtMs,
        ),
        peerId: 'probe-peer',
        priority: MeshMessagePriority.callSignal,
        nowMs: probeAtMs,
      );
      expect(expiredProbe.disposition, MeshDisposition.expired);

      final replayedId = tally.deliveredFrames.first.messageId;
      final duplicateProbe = await processor.process(
        _frame(messageId: replayedId, createdAtMs: probeAtMs),
        peerId: 'probe-peer',
        priority: MeshMessagePriority.callSignal,
        nowMs: probeAtMs,
      );
      expect(duplicateProbe.disposition, MeshDisposition.duplicate);
    });
  });

  group('GuardedMeshOutcome sealed hierarchy', () {
    test('an exhaustive switch (no default) matches both variants', () {
      String describe(GuardedMeshOutcome outcome) {
        return switch (outcome) {
          AdmittedMeshOutcome(disposition: final d) => 'admitted:$d',
          ShedMeshOutcome(rejection: final r) => 'shed:$r',
        };
      }

      final admitted = GuardedMeshOutcome.admitted(MeshDisposition.delivered);
      final shed = GuardedMeshOutcome.shed(MeshFlowRejection.rateLimited);

      expect(admitted, isA<AdmittedMeshOutcome>());
      expect(shed, isA<ShedMeshOutcome>());
      expect(describe(admitted), 'admitted:MeshDisposition.delivered');
      expect(describe(shed), 'shed:MeshFlowRejection.rateLimited');

      // The pre-existing getter surface survives on the base type.
      expect(admitted.admitted, isTrue);
      expect(admitted.disposition, MeshDisposition.delivered);
      expect(admitted.rejection, isNull);
      expect(shed.admitted, isFalse);
      expect(shed.disposition, isNull);
      expect(shed.rejection, MeshFlowRejection.rateLimited);
    });
  });
}

class _SimulationTally {
  final Map<MeshMessagePriority, int> sentByPriority = {
    for (final priority in MeshMessagePriority.values) priority: 0,
  };
  final Map<MeshMessagePriority, int> admittedByPriority = {
    for (final priority in MeshMessagePriority.values) priority: 0,
  };
  final Map<String, int> deliveredByPeer = {};
  final List<MediaFrame> deliveredFrames = [];
  int quotaShed = 0;
  int rateShed = 0;
  int duplicates = 0;
  int expired = 0;
  int other = 0;
}
