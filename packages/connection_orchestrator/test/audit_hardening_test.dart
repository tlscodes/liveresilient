// Regression tests for the defects found in the 2026-07-27 architecture
// audit of connection_orchestrator. Each group names the defect it pins.
import 'dart:convert';
import 'dart:typed_data';

import 'package:connection_orchestrator/src/carrier_relay.dart';
import 'package:connection_orchestrator/src/chunked_transfer.dart';
import 'package:connection_orchestrator/src/cold_start_dictionary.dart';
import 'package:connection_orchestrator/src/gf256_rlnc_stream.dart';
import 'package:connection_orchestrator/src/rateless_stream.dart';
import 'package:test/test.dart';

void main() {
  group('constructor bounds hold without asserts (release-mode safety)', () {
    test('ResumableTransfer rejects a zero chunkSize with ArgumentError', () {
      expect(
        () => ResumableTransfer(
          transferId: 't',
          payload: List<int>.filled(10, 1),
          chunkSize: 0,
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('ResumableTransfer rejects a parity group smaller than two', () {
      expect(
        () => ResumableTransfer(
          transferId: 't',
          payload: List<int>.filled(10, 1),
          parityGroupSize: 1,
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('RatelessEncoder rejects an out-of-range blockSize', () {
      final data = Uint8List.fromList(List<int>.filled(64, 7));
      expect(
        () => RatelessEncoder(data, blockSize: 0),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => RatelessEncoder(data, blockSize: 56),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('RlncEncoder rejects an out-of-range blockSize', () {
      final data = Uint8List.fromList(List<int>.filled(64, 7));
      expect(
        () => RlncEncoder(data, blockSize: 0),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('ChunkReassembler bounds and total-pinning', () {
    test('a later bundle claiming a different total is rejected, not '
        'allowed to truncate the payload', () {
      final r = ChunkReassembler();
      // Three chunks announced, all three delivered but not yet spliced.
      expect(r.accept('tx#0/3', [1]), isNull);
      expect(r.accept('tx#1/3', [2]), isNull);
      // A forged bundle shrinking the count to 1 must not complete the
      // transfer with a 1-byte "payload".
      expect(r.accept('tx#0/1', [9]), isNull);
      expect(r.accept('tx#2/3', [3]), equals([1, 2, 3]));
    });

    test('a total that grows is rejected too', () {
      final r = ChunkReassembler();
      expect(r.accept('tx#0/2', [1]), isNull);
      expect(r.accept('tx#1/9', [5]), isNull);
      expect(r.accept('tx#1/2', [2]), equals([1, 2]));
    });

    test('memory stays bounded when transfers are opened and abandoned', () {
      final r = ChunkReassembler(maxOpenTransfers: 8);
      for (var i = 0; i < 500; i++) {
        r.accept('bogus-$i#0/50', [1, 2, 3]);
      }
      expect(r.openTransfers, lessThanOrEqualTo(8));
    });

    test('eviction drops the oldest open transfer, keeping the newest', () {
      final r = ChunkReassembler(maxOpenTransfers: 2);
      r.accept('a#0/2', [1]);
      r.accept('b#0/2', [1]);
      r.accept('c#0/2', [1]);
      expect(r.openTransfers, 2);
      // 'a' was evicted: its second chunk starts a fresh transfer rather
      // than completing the old one.
      expect(r.accept('a#1/2', [2]), isNull);
      // 'c' survived and completes normally.
      expect(r.accept('c#1/2', [2]), equals([1, 2]));
    });

    test('forget releases a transfer that will never finish', () {
      final r = ChunkReassembler();
      r.accept('tx#0/4', [1]);
      expect(r.openTransfers, 1);
      expect(r.forget('tx'), isTrue);
      expect(r.openTransfers, 0);
      expect(r.forget('tx'), isFalse);
    });

    test('a completed transfer leaves no state behind', () {
      final r = ChunkReassembler();
      r.accept('tx#0/2', [1]);
      expect(r.accept('tx#1/2', [2]), equals([1, 2]));
      expect(r.openTransfers, 0);
    });
  });

  group('CarrierRelay honours its bounds on restore', () {
    CustodyBundle bundle(String id, {int hops = 0, int bytes = 4}) =>
        CustodyBundle(
          bundleId: id,
          destination: 'dest',
          payload: List<int>.filled(bytes, 1),
          acceptedAtMs: 0,
          lifetimeMs: 1000000,
          hopCount: hops,
        );

    test('restore refuses rows beyond capacityBundles', () {
      final persisted = [for (var i = 0; i < 20; i++) bundle('b$i').toJson()];
      final relay = CarrierRelay(capacityBundles: 5);
      final restored = relay.restore(persisted, nowMs: 1);
      expect(restored, 5);
      expect(relay.heldCount, 5);
    });

    test('restore refuses rows beyond capacityBytes', () {
      final persisted = [
        for (var i = 0; i < 10; i++) bundle('b$i', bytes: 100).toJson(),
      ];
      final relay = CarrierRelay(capacityBytes: 250);
      relay.restore(persisted, nowMs: 1);
      expect(relay.heldBytes, lessThanOrEqualTo(250));
    });

    test('restore refuses a row that already exceeded the hop limit', () {
      final relay = CarrierRelay(maxHops: 3);
      final restored = relay.restore([
        bundle('ok', hops: 1).toJson(),
        bundle('looped', hops: 9).toJson(),
      ], nowMs: 1);
      expect(restored, 1);
      expect(relay.heldCount, 1);
    });

    test('the dedup vector is capped instead of growing forever', () {
      final relay = CarrierRelay(maxSeenIds: 16, capacityBundles: 1000);
      for (var i = 0; i < 400; i++) {
        relay.accept(bundle('b$i'), nowMs: 1);
      }
      expect(relay.summaryVector().length, lessThanOrEqualTo(16));
    });

    test('a live duplicate is still refused while its id is remembered', () {
      final relay = CarrierRelay();
      expect(relay.accept(bundle('x'), nowMs: 1), isNull);
      expect(relay.accept(bundle('x'), nowMs: 1), CustodyRefusal.duplicate);
    });
  });

  group('ColdStartDictionary warm-state adoption', () {
    Uint8List crcWrapped(String body) {
      final raw = utf8.encode(body);
      final out = Uint8List(raw.length + 1);
      out.setAll(0, raw);
      out[raw.length] = crc8(out, raw.length);
      return out;
    }

    test('a CRC-valid payload whose JSON is not an object returns false '
        'instead of throwing TypeError', () {
      final dict = ColdStartDictionaryManager();
      expect(dict.adoptWarmState(crcWrapped('42')), isFalse);
      expect(dict.adoptWarmState(crcWrapped('[1,2,3]')), isFalse);
      expect(dict.adoptWarmState(crcWrapped('"a string"')), isFalse);
      expect(dict.phase, isNot(DictionaryPhase.dynamicWarm));
    });

    test('a CRC-valid payload of non-JSON bytes returns false', () {
      final dict = ColdStartDictionaryManager();
      expect(dict.adoptWarmState(crcWrapped('not json at all')), isFalse);
    });

    test('a well-formed warm state is still adopted', () {
      final dict = ColdStartDictionaryManager();
      final packed = ColdStartDictionaryManager.packWarmState(
        ColdStartDictionaryManager.baseState(),
      );
      expect(dict.adoptWarmState(packed), isTrue);
      expect(dict.phase, DictionaryPhase.dynamicWarm);
    });
  });
}
