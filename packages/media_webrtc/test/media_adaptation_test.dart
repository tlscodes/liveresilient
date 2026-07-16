import 'dart:math';
import 'dart:typed_data';

import 'package:media_webrtc/media_webrtc.dart';
import 'package:test/test.dart';

MediaPacket _packet(int sequence, int senderTimestampMs, [List<int>? payload]) {
  return MediaPacket(
    sequenceNumber: sequence,
    senderTimestampMs: senderTimestampMs,
    payload: payload ?? <int>[sequence & 0xff],
  );
}

void main() {
  group('AdaptiveJitterBuffer in-order stream', () {
    test('plays every packet in order with zero drops and zero jitter', () {
      final buffer = AdaptiveJitterBuffer();

      // Constant sender spacing and identical network transit time:
      // inter-arrival variation is zero, so jitter stays zero and the
      // playout delay stays at the minimum.
      for (var i = 0; i < 10; i++) {
        final accepted = buffer.addPacket(
          _packet(i, 1000 + 20 * i),
          arrivalMs: 2000 + 20 * i,
        );
        expect(accepted, isTrue, reason: 'packet $i must be accepted');
      }

      expect(buffer.bufferedPacketCount, 10);
      expect(buffer.estimatedJitterMs, 0);
      expect(buffer.targetDelayMs, buffer.minimumDelayMs);

      // Scheduled playout of packet i: firstArrival (2000) + 20i + 60.
      expect(buffer.takeNext(nowMs: 2059), isNull, reason: 'still buffering');

      for (var i = 0; i < 10; i++) {
        final played = buffer.takeNext(nowMs: 2060 + 20 * i);
        expect(played, isNotNull, reason: 'packet $i due at ${2060 + 20 * i}');
        expect(played!.sequenceNumber, i);
      }

      expect(buffer.takeNext(nowMs: 3000), isNull);
      expect(buffer.droppedLate, 0);
      expect(buffer.droppedDuplicates, 0);
      expect(buffer.droppedOverflow, 0);
    });

    test('16-bit sequence wraparound keeps playout order across the cycle', () {
      final buffer = AdaptiveJitterBuffer();
      final sequences = [0xfffe, 0xffff, 0x0000, 0x0001];

      for (var i = 0; i < sequences.length; i++) {
        expect(
          buffer.addPacket(
            _packet(sequences[i], 1000 + 20 * i),
            arrivalMs: 2000 + 20 * i,
          ),
          isTrue,
        );
      }

      for (var i = 0; i < sequences.length; i++) {
        final played = buffer.takeNext(nowMs: 2060 + 20 * i);
        expect(played, isNotNull);
        expect(
          played!.sequenceNumber,
          sequences[i],
          reason: 'wrapped stream must play in sender order',
        );
      }
    });
  });

  group('AdaptiveJitterBuffer reordering', () {
    test(
      'packets reordered within the window are played in sequence order',
      () {
        final buffer = AdaptiveJitterBuffer();

        // Seq 1 arrives after seq 2 (arrival timestamps stay monotonic).
        buffer.addPacket(_packet(0, 1000), arrivalMs: 2000);
        buffer.addPacket(_packet(2, 1040), arrivalMs: 2040);
        buffer.addPacket(_packet(1, 1020), arrivalMs: 2041);

        final played = <int>[];
        for (final nowMs in [2060, 2080, 2100]) {
          final packet = buffer.takeNext(nowMs: nowMs);
          expect(packet, isNotNull, reason: 'due at $nowMs');
          played.add(packet!.sequenceNumber);
        }

        expect(played, [0, 1, 2]);
        expect(buffer.droppedLate, 0);
        expect(buffer.droppedDuplicates, 0);
      },
    );

    test('a reordered (older) packet does not create a jitter spike', () {
      final buffer = AdaptiveJitterBuffer();

      buffer.addPacket(_packet(0, 1000), arrivalMs: 2000);
      buffer.addPacket(_packet(2, 1040), arrivalMs: 2040);
      // Old packet with a large arrival-vs-sender delta: must be excluded
      // from the timing estimator (it is older than the last timing sample).
      buffer.addPacket(_packet(1, 1020), arrivalMs: 2200);

      expect(buffer.estimatedJitterMs, 0);
    });
  });

  group('AdaptiveJitterBuffer drop counters', () {
    test('a packet older than the playout position increments droppedLate', () {
      final buffer = AdaptiveJitterBuffer();

      buffer.addPacket(_packet(0, 1000), arrivalMs: 2000);
      buffer.addPacket(_packet(2, 1040), arrivalMs: 2040);

      expect(buffer.takeNext(nowMs: 2060)!.sequenceNumber, 0);
      expect(buffer.takeNext(nowMs: 2100)!.sequenceNumber, 2);

      // Seq 1 shows up only after seq 2 has already been played.
      final accepted = buffer.addPacket(_packet(1, 1020), arrivalMs: 2150);
      expect(accepted, isFalse);
      expect(buffer.droppedLate, 1);
      expect(buffer.bufferedPacketCount, 0);
    });

    test('a buffered packet stale past lateDropThresholdMs is dropped at '
        'playout time', () {
      final buffer = AdaptiveJitterBuffer(
        minimumDelayMs: 60,
        lateDropThresholdMs: 250,
      );

      buffer.addPacket(_packet(0, 1000), arrivalMs: 2000);

      // Scheduled playout is 2060; 2311 is exactly at the threshold edge
      // (2311 - 2060 = 251 > 250), so the packet must be discarded.
      expect(buffer.takeNext(nowMs: 2311), isNull);
      expect(buffer.droppedLate, 1);
      expect(buffer.bufferedPacketCount, 0);
    });

    test(
      'a duplicate of a still-buffered packet increments droppedDuplicates',
      () {
        final buffer = AdaptiveJitterBuffer();

        expect(buffer.addPacket(_packet(5, 1000), arrivalMs: 2000), isTrue);
        expect(buffer.addPacket(_packet(5, 1000), arrivalMs: 2010), isFalse);

        expect(buffer.droppedDuplicates, 1);
        expect(buffer.bufferedPacketCount, 1);
      },
    );

    test('exceeding maximumPackets drops the oldest and counts overflow', () {
      final buffer = AdaptiveJitterBuffer(maximumPackets: 4);

      for (var i = 0; i < 6; i++) {
        buffer.addPacket(_packet(i, 1000 + 20 * i), arrivalMs: 2000 + 20 * i);
      }

      expect(buffer.droppedOverflow, 2);
      expect(buffer.bufferedPacketCount, 4);

      // Oldest packets (0 and 1) were evicted; playout starts at seq 2,
      // whose scheduled playout is firstArrival (2000) + 40 + 60 = 2100.
      final first = buffer.takeNext(nowMs: 2100);
      expect(first, isNotNull);
      expect(first!.sequenceNumber, 2);
    });

    test('non-monotonic arrival timestamps throw ArgumentError', () {
      final buffer = AdaptiveJitterBuffer();
      buffer.addPacket(_packet(0, 1000), arrivalMs: 2000);
      expect(
        () => buffer.addPacket(_packet(1, 1020), arrivalMs: 1999),
        throwsArgumentError,
      );
    });
  });

  group('AdaptiveJitterBuffer adaptive delay (seeded Random)', () {
    test('jitter estimate grows under variable inter-arrival times', () {
      final rng = Random(42);
      final buffer = AdaptiveJitterBuffer();

      var arrivalMs = 2000;
      for (var i = 0; i < 200; i++) {
        // Sender paces exactly 20 ms; the network delivers with a random
        // inter-arrival between 5 and 44 ms (monotonic by construction).
        arrivalMs += 5 + rng.nextInt(40);
        buffer.addPacket(_packet(i, 1000 + 20 * i), arrivalMs: arrivalMs);
      }

      expect(buffer.estimatedJitterMs, greaterThan(0));
      expect(buffer.targetDelayMs, greaterThan(buffer.minimumDelayMs));
      expect(buffer.targetDelayMs, lessThanOrEqualTo(buffer.maximumDelayMs));
    });

    test('playout delay is clamped to maximumDelayMs under extreme jitter', () {
      final buffer = AdaptiveJitterBuffer(
        minimumDelayMs: 60,
        maximumDelayMs: 200,
      );

      var arrivalMs = 2000;
      for (var i = 0; i < 64; i++) {
        // Alternate instant delivery and a 400 ms stall: sustained huge
        // inter-arrival variation drives the EWMA far above the clamp.
        arrivalMs += i.isEven ? 1 : 400;
        buffer.addPacket(_packet(i, 1000 + 20 * i), arrivalMs: arrivalMs);
      }

      expect(buffer.estimatedJitterMs, greaterThan(35));
      expect(buffer.targetDelayMs, buffer.maximumDelayMs);
    });

    test('zero-jitter stream keeps the playout delay at minimumDelayMs', () {
      final buffer = AdaptiveJitterBuffer();
      for (var i = 0; i < 50; i++) {
        buffer.addPacket(_packet(i, 1000 + 20 * i), arrivalMs: 3000 + 20 * i);
      }
      expect(buffer.estimatedJitterMs, 0);
      expect(buffer.targetDelayMs, buffer.minimumDelayMs);
    });
  });

  group('AdaptiveJitterBuffer clear/empty behavior', () {
    test('takeNext on an empty buffer returns null', () {
      final buffer = AdaptiveJitterBuffer();
      expect(buffer.takeNext(nowMs: 0), isNull);
      expect(buffer.bufferedPacketCount, 0);
    });

    test('clear resets queue, counters, jitter and timing state', () {
      final rng = Random(7);
      final buffer = AdaptiveJitterBuffer(maximumPackets: 8);

      var arrivalMs = 2000;
      for (var i = 0; i < 20; i++) {
        arrivalMs += 5 + rng.nextInt(40);
        buffer.addPacket(_packet(i, 1000 + 20 * i), arrivalMs: arrivalMs);
      }
      buffer.addPacket(_packet(19, 1380), arrivalMs: arrivalMs); // duplicate
      expect(buffer.droppedOverflow, greaterThan(0));

      buffer.clear();

      expect(buffer.bufferedPacketCount, 0);
      expect(buffer.estimatedJitterMs, 0);
      expect(buffer.targetDelayMs, buffer.minimumDelayMs);
      expect(buffer.droppedLate, 0);
      expect(buffer.droppedDuplicates, 0);
      expect(buffer.droppedOverflow, 0);
      expect(buffer.takeNext(nowMs: arrivalMs + 1000), isNull);

      // After clear the buffer accepts a brand-new stream, including
      // arrival timestamps earlier than the previous stream's.
      expect(buffer.addPacket(_packet(100, 1), arrivalMs: 10), isTrue);
      expect(buffer.takeNext(nowMs: 10 + buffer.targetDelayMs), isNotNull);
    });
  });

  group('XorFec encode/recover', () {
    final packets = <List<int>>[
      [1, 2, 3, 4, 5],
      [10, 20, 30],
      [7, 7, 7, 7, 7, 7, 7],
      [0, 255, 128, 64],
    ];

    test('recovers exactly one missing shard, byte-exact, any position', () {
      final block = XorFec.encode(blockId: 1, packets: packets);
      expect(block.dataShardCount, packets.length);
      expect(block.maximumShardLength, 7);

      for (var missing = 0; missing < packets.length; missing++) {
        final received = <Uint8List?>[
          for (var i = 0; i < packets.length; i++)
            i == missing ? null : Uint8List.fromList(packets[i]),
        ];

        final recovered = XorFec.recover(
          block: block,
          receivedDataShards: received,
        );

        expect(recovered, isNotNull, reason: 'missing shard $missing');
        expect(recovered!.index, missing);
        expect(
          recovered.data,
          packets[missing],
          reason: 'shard $missing must round-trip byte-exact',
        );
      }
    });

    test('refuses gracefully when two shards are missing (returns null)', () {
      // Single-parity XOR FEC cannot reconstruct two losses; the correct
      // behavior is a null result, never garbage data or a throw.
      final block = XorFec.encode(blockId: 2, packets: packets);
      final received = <Uint8List?>[
        null,
        null,
        Uint8List.fromList(packets[2]),
        Uint8List.fromList(packets[3]),
      ];

      expect(
        XorFec.recover(block: block, receivedDataShards: received),
        isNull,
      );
    });

    test('returns null when nothing is missing', () {
      final block = XorFec.encode(blockId: 3, packets: packets);
      final received = <Uint8List?>[
        for (final p in packets) Uint8List.fromList(p),
      ];
      expect(
        XorFec.recover(block: block, receivedDataShards: received),
        isNull,
      );
    });

    test('a shard with a tampered length raises FormatException', () {
      final block = XorFec.encode(blockId: 4, packets: packets);
      final received = <Uint8List?>[
        Uint8List.fromList([1, 2, 3, 4, 5, 99]), // one byte too long
        null,
        Uint8List.fromList(packets[2]),
        Uint8List.fromList(packets[3]),
      ];

      expect(
        () => XorFec.recover(block: block, receivedDataShards: received),
        throwsFormatException,
      );
    });

    test('a parity blob with the wrong length raises FormatException', () {
      final block = XorFec.encode(blockId: 5, packets: packets);
      final received = <Uint8List?>[
        null,
        Uint8List.fromList(packets[1]),
        Uint8List.fromList(packets[2]),
        Uint8List.fromList(packets[3]),
      ];

      expect(
        () => XorFec.recover(
          block: block,
          receivedDataShards: received,
          receivedParity: Uint8List(block.maximumShardLength + 1),
        ),
        throwsFormatException,
      );
    });

    test('a wrong shard count raises ArgumentError', () {
      final block = XorFec.encode(blockId: 6, packets: packets);
      expect(
        () => XorFec.recover(
          block: block,
          receivedDataShards: <Uint8List?>[null],
        ),
        throwsArgumentError,
      );
    });

    test('encode rejects an empty packet list', () {
      expect(
        () => XorFec.encode(blockId: 7, packets: const []),
        throwsArgumentError,
      );
    });

    test('property: random blocks round-trip any single loss (Random(7))', () {
      final rng = Random(7);
      for (var iteration = 0; iteration < 100; iteration++) {
        final shardCount = 1 + rng.nextInt(8);
        final shards = <List<int>>[
          for (var s = 0; s < shardCount; s++)
            [for (var b = 0; b < rng.nextInt(65); b++) rng.nextInt(256)],
        ];

        final block = XorFec.encode(blockId: iteration, packets: shards);
        final missing = rng.nextInt(shardCount);
        final received = <Uint8List?>[
          for (var i = 0; i < shardCount; i++)
            i == missing ? null : Uint8List.fromList(shards[i]),
        ];

        final recovered = XorFec.recover(
          block: block,
          receivedDataShards: received,
        );

        expect(recovered, isNotNull, reason: 'iteration $iteration');
        expect(recovered!.index, missing, reason: 'iteration $iteration');
        expect(
          recovered.data,
          shards[missing],
          reason: 'iteration $iteration: shard $missing of $shardCount',
        );
      }
    });
  });
}
