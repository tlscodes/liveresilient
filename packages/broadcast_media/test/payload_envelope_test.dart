import 'dart:typed_data';

import 'package:broadcast_media/broadcast_media.dart';
import 'package:test/test.dart';

Uint8List _bytes(int length, [int seed = 1]) =>
    Uint8List.fromList(List.generate(length, (i) => (i * seed + 7) & 0xFF));

void main() {
  group('PayloadEnvelope', () {
    test('round-trips every kind', () {
      for (final kind in PayloadKind.values) {
        final body = _bytes(40, kind.tag);
        final decoded = PayloadEnvelope.decode(
          PayloadEnvelope(kind: kind, body: body).encode(),
        );
        expect(decoded, isNotNull, reason: '$kind');
        expect(decoded!.kind, kind);
        expect(decoded.body, body);
      }
    });

    test('the tag values are wire constants', () {
      // Renumbering one silently reinterprets every stored payload.
      expect(PayloadKind.text.tag, 1);
      expect(PayloadKind.imageLevel.tag, 2);
      expect(PayloadKind.voiceTokens.tag, 3);
      expect(PayloadKind.videoFrame.tag, 4);
      expect(PayloadKind.bundle.tag, 5);
    });

    test('an empty body is allowed and costs two bytes', () {
      final encoded = PayloadEnvelope(
        kind: PayloadKind.text,
        body: Uint8List(0),
      ).encode();
      expect(encoded.length, 2);
      expect(PayloadEnvelope.decode(encoded)!.body, isEmpty);
    });

    test('refuses an unknown tag rather than guessing', () {
      expect(PayloadEnvelope.decode(Uint8List.fromList([99, 1, 5])), isNull);
      expect(PayloadEnvelope.decode(Uint8List.fromList([0, 1, 5])), isNull);
    });

    test('refuses an unknown version', () {
      expect(PayloadEnvelope.decode(Uint8List.fromList([1, 2, 5])), isNull);
    });

    test('refuses a buffer too short to hold a header', () {
      expect(PayloadEnvelope.decode(Uint8List(0)), isNull);
      expect(PayloadEnvelope.decode(Uint8List(1)), isNull);
    });
  });

  group('ImageLevelPayload', () {
    test('carries the geometry a subset-holding reader needs', () {
      final payload = ImageLevelPayload(
        width: 640,
        height: 480,
        coderIndex: 2,
        bytes: _bytes(64),
      );
      final decoded = ImageLevelPayload.decode(payload.encode());
      expect(decoded!.width, 640);
      expect(decoded.height, 480);
      expect(decoded.coderIndex, 2);
      expect(decoded.bytes, payload.bytes);
    });

    test('refuses a zero dimension and a truncated header', () {
      final zero = ImageLevelPayload(
        width: 0,
        height: 10,
        coderIndex: 0,
        bytes: _bytes(4),
      ).encode();
      expect(ImageLevelPayload.decode(zero), isNull);
      expect(ImageLevelPayload.decode(Uint8List(4)), isNull);
    });
  });

  group('VideoFramePayload', () {
    test('round-trips index and predictor', () {
      final payload = VideoFramePayload(
        index: 300,
        predictorIndex: 2,
        bytes: _bytes(32),
      );
      final decoded = VideoFramePayload.decode(payload.encode());
      expect(decoded!.index, 300);
      expect(decoded.predictorIndex, 2);
      expect(decoded.bytes, payload.bytes);
    });

    test('refuses a truncated header', () {
      expect(VideoFramePayload.decode(Uint8List(3)), isNull);
    });
  });

  group('PayloadBundle', () {
    PayloadEnvelope part(int i) => PayloadEnvelope(
      kind: PayloadKind.imageLevel,
      body: _bytes(10 + i, i + 1),
    );

    test('round-trips parts in order', () {
      final bundle = PayloadBundle([part(0), part(1), part(2)]);
      final decoded = PayloadBundle.decode(bundle.encode());
      expect(decoded!.parts, hasLength(3));
      for (var i = 0; i < 3; i++) {
        expect(decoded.parts[i].body, part(i).body);
      }
    });

    test('an empty bundle round-trips', () {
      expect(
        PayloadBundle.decode(const PayloadBundle([]).encode())!.parts,
        isEmpty,
      );
    });

    test('refuses a truncated bundle rather than decoding a prefix', () {
      // Partial delivery is the transport's job, and it already verifies
      // whole layers by hash.
      final encoded = PayloadBundle([part(0), part(1)]).encode();
      expect(
        PayloadBundle.decode(
          Uint8List.fromList(encoded.sublist(0, encoded.length - 3)),
        ),
        isNull,
      );
    });

    test('refuses trailing bytes', () {
      final encoded = PayloadBundle([part(0)]).encode();
      expect(PayloadBundle.decode(Uint8List.fromList([...encoded, 0])), isNull);
    });

    test('refuses a count larger than the buffer can hold', () {
      // The hostile case: a huge declared count with no bytes behind it.
      final bad = Uint8List(3);
      bad[0] = payloadVersion;
      ByteData.sublistView(bad).setUint16(1, 200);
      expect(PayloadBundle.decode(bad), isNull);
    });

    test('refuses a count above the ceiling', () {
      final bad = Uint8List(3);
      bad[0] = payloadVersion;
      ByteData.sublistView(bad).setUint16(1, maxBundleParts + 1);
      expect(PayloadBundle.decode(bad), isNull);
    });

    test('refuses a part length past the payload ceiling', () {
      final bad = Uint8List(7);
      bad[0] = payloadVersion;
      final view = ByteData.sublistView(bad)
        ..setUint16(1, 1)
        ..setUint32(3, maxPayloadBytes + 1);
      expect(view.getUint32(3), maxPayloadBytes + 1);
      expect(PayloadBundle.decode(bad), isNull);
    });

    test('refuses an unknown version and a runt buffer', () {
      final encoded = PayloadBundle([part(0)]).encode();
      expect(
        PayloadBundle.decode(Uint8List.fromList(encoded)..[0] = 9),
        isNull,
      );
      expect(PayloadBundle.decode(Uint8List(2)), isNull);
    });

    test('refuses more parts than the ceiling on encode', () {
      expect(
        () => PayloadBundle([
          for (var i = 0; i <= maxBundleParts; i++) part(0),
        ]).encode(),
        throwsArgumentError,
      );
    });
  });
}
