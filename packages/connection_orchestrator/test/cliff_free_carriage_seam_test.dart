/// The seam nobody had crossed: a cliff-free transfer id, put through the
/// carrier that is documented as carrying it.
///
/// WHY THIS FILE EXISTS. `cliff_free_inbox.dart` opens with the claim that
/// "`TaggedDatagram.transferId` is already carried by `MediaCarriage` for every
/// datagram", and the whole cliff-free addressing scheme rests on it: nothing
/// about the object, the layer, or the layer count appears inside the 60-byte
/// RLNC datagram. It is ALL in the transfer id.
///
/// `MediaCarriage.maxTransferId` is `0xFFFF`. `CliffFreeTransferId.raw` is 32
/// bits. Both files are green, both are fully unit-tested, and no test in the
/// repository had ever handed one to the other — because the send path calls
/// its caller's `sink` directly and never goes through the carrier at all.
///
/// Every test here is an executable statement about that seam. They are not
/// hypotheses: run them and the answer is on the terminal.
@TestOn('vm')
library;

import 'dart:typed_data';

import 'package:connection_orchestrator/connection_orchestrator.dart';
import 'package:test/test.dart';

/// A 60-second clip at 2-second segments, which §15.4 of CLIFF-FREE-VIDEO
/// specifies as one object whose LAYERS ARE THE TIME SEGMENTS.
///
/// The number matters to the conclusion. If the design only ever needed a
/// handful of layers, shrinking the id to fit the carrier would be free. Thirty
/// segments is past four bits, so it is not free, and the test says so with the
/// real number rather than with an assumed one.
const int _segmentsInA60sClip = 30;

Uint8List _datagram() {
  final encoder = RlncEncoder(
    Uint8List.fromList(List.generate(600, (i) => i & 0xFF)),
    blockSize: LayeredRedundancyAllocator.mandatedBlockSize,
  );
  return encoder.datagramAt(0);
}

void main() {
  group('the addressing the design uses', () {
    test('a realistic video object needs more than 16 bits of transfer id', () {
      final last = CliffFreeTransferId.of(
        objectId: 1,
        layerCount: _segmentsInA60sClip,
        layerIndex: _segmentsInA60sClip - 1,
      );

      // Not a style opinion: the value itself does not fit.
      expect(
        last.raw,
        greaterThan(MediaCarriage.maxTransferId),
        reason: 'objectId 1 with 30 segments already exceeds the carrier cap',
      );

      // And the fields survive the round trip through the packed integer, so
      // the 32-bit layout is doing real work rather than wasting space.
      expect(last.objectId, 1);
      expect(last.layerCount, _segmentsInA60sClip);
      expect(last.layerIndex, _segmentsInA60sClip - 1);
    });

    test('even the smallest possible object exceeds the cap once objectId > 0',
        () {
      // One object, one layer — the minimum the scheme can express. objectId
      // occupies the HIGH sixteen bits, so any object past the first is already
      // over 0xFFFF regardless of how few layers it has. The cap is not a
      // ceiling the design occasionally brushes; it is crossed on the second
      // object ever sent.
      final second = CliffFreeTransferId.of(
        objectId: 1,
        layerCount: 1,
        layerIndex: 0,
      );
      expect(second.raw, greaterThan(MediaCarriage.maxTransferId));
    });
  });

  group('what the carrier does with it', () {
    test('MediaCarriage.wrap REFUSES a real cliff-free transfer id', () {
      final carriage = MediaCarriage(carrier: MediaCarrier.sctpDataChannel);
      final id = CliffFreeTransferId.of(
        objectId: 1,
        layerCount: _segmentsInA60sClip,
        layerIndex: 0,
      );

      // This is the finding. Not "might be lossy", not "needs care": the only
      // wire encoder in the package throws on the only addressing the
      // cliff-free path has.
      expect(
        () => carriage.wrap(TaggedDatagram(id.raw, _datagram())),
        throwsA(isA<ArgumentError>()),
        reason: 'the carrier documented as carrying this id rejects it',
      );
    });

    test('the failure would have been SILENT if wrap had merely truncated', () {
      // Why the throw is the good outcome, and why this test guards it.
      //
      // Two distinct objects collide the moment the high bits are discarded:
      // object 1 layer 0 of 30, and object 2 layer 0 of 30, differ only above
      // bit 16. A carrier that masked instead of throwing would deliver both
      // into ONE reassembler, and the inbox's own aliasing guard could not see
      // it — the layerCounts match, so nothing looks wrong. The receiver would
      // decode a photo built from two different photos' symbols and render it
      // as a successful transfer.
      final a = CliffFreeTransferId.of(
        objectId: 1,
        layerCount: _segmentsInA60sClip,
        layerIndex: 0,
      );
      final b = CliffFreeTransferId.of(
        objectId: 2,
        layerCount: _segmentsInA60sClip,
        layerIndex: 0,
      );

      expect(a.raw, isNot(b.raw));
      expect(
        a.raw & MediaCarriage.maxTransferId,
        b.raw & MediaCarriage.maxTransferId,
        reason: 'truncation maps two objects onto one address',
      );

      // The SCTP unwrap path reads exactly two bytes, so truncation is what
      // the format would do if the guard were removed.
      expect(MediaCarriage.maxTransferId, 0xFFFF);
    });

    test('the HTTP/2 carrier could express it; the SCTP field is the limit',
        () {
      // Worth separating, because it changes what a fix costs. HTTP/2 stream
      // ids are 31 bits, so `streamIdFor` has room to spare for a 32-bit
      // transfer id; the 0xFFFF cap is imposed by the DataChannel path's
      // two-byte prefix and then applied to BOTH carriers by `wrap`.
      final id = CliffFreeTransferId.of(
        objectId: 300,
        layerCount: _segmentsInA60sClip,
        layerIndex: 7,
      );
      final streamId = MediaCarriage.streamIdFor(id.raw);
      expect(streamId.isOdd, isTrue);
      expect(streamId, lessThan(1 << 31), reason: 'fits an HTTP/2 stream id');
      expect(MediaCarriage.transferIdForStream(streamId), id.raw);
    });
  });

  group('the type now travels, and the send path fits its carrier', () {
    test('the media type ARRIVES instead of being guessed by the receiver',
        () async {
      // This test used to pin the gap: `sendCliffFree` accepted a MediaType,
      // put it nowhere, and `accept` demanded one — so the receiving side
      // invented the value that decides how an object renders, and sending as
      // photo while accepting as document raised no objection anywhere.
      //
      // With the address in the batch header the type is on the wire, and the
      // receiver has no parameter left to get wrong.
      for (final sentAs in [MediaType.photo, MediaType.flipbook]) {
        final transport = ResilientMediaTransport();
        final frames = <Uint8List>[];

        await transport.sendCliffFree(
          [
            MediaLayer(
              Uint8List.fromList(List.filled(200, 3)),
              kind: LayerKind.base,
            ),
          ],
          sentAs,
          sink: (objectId, frame) async {
            frames.add(frame);
            return true;
          },
          budgetBytes: 4096,
        );

        expect(frames, isNotEmpty);
        for (final f in frames) {
          expect(CliffFreeBatchCodec.decode(f).type, sentAs);
        }
      }
    });

    test('every frame the send path emits SURVIVES the carrier', () async {
      // The contract that replaces the defect above. Under the old scheme
      // `wrap` threw on the second object ever sent; the loop here allocates
      // several objects precisely so that objectId is not 0.
      final transport = ResilientMediaTransport();
      final carriage = MediaCarriage(carrier: MediaCarrier.sctpDataChannel);

      for (var round = 0; round < 4; round++) {
        final frames = <(int, Uint8List)>[];
        await transport.sendCliffFree(
          [
            MediaLayer(
              Uint8List.fromList(List.filled(900, round)),
              kind: LayerKind.base,
            ),
            MediaLayer(Uint8List.fromList(List.filled(900, round + 100))),
          ],
          MediaType.photo,
          sink: (objectId, frame) async {
            frames.add((objectId, frame));
            return true;
          },
          budgetBytes: 64 * 1024,
        );

        expect(frames, isNotEmpty, reason: 'round $round');
        for (final (objectId, frame) in frames) {
          expect(objectId, greaterThan(0));
          // The whole point: this is the call that used to throw.
          final wire = carriage.wrap(TaggedDatagram(objectId, frame));
          final back = carriage.unwrap(wire);
          expect(back.transferId, objectId);
          expect(CliffFreeBatchCodec.decode(back.bytes).objectId, objectId);
        }
      }
    });

    test('a sink that refuses is never called again, including for the tail',
        () async {
      // The tail flush after `send` returns is real data, but a sink that
      // already said stop means a full lane or a closed session, and pushing
      // one more frame at it is exactly the bug the flush was written to
      // avoid on the other side.
      final transport = ResilientMediaTransport();
      var calls = 0;

      await transport.sendCliffFree(
        [
          MediaLayer(
            Uint8List.fromList(List.filled(4000, 7)),
            kind: LayerKind.base,
          ),
        ],
        MediaType.photo,
        sink: (objectId, frame) async {
          calls++;
          return false; // refuse immediately
        },
        budgetBytes: 256 * 1024,
      );

      expect(calls, 1, reason: 'refused once, then called again');
    });
  });
}
