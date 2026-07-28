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
        ordinal: 1,
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
        ordinal: 0,
        width: 0,
        height: 10,
        coderIndex: 0,
        bytes: _bytes(4),
      ).encode();
      expect(ImageLevelPayload.decode(zero), isNull);
      expect(ImageLevelPayload.decode(Uint8List(4)), isNull);
    });

    test('refuses a declared size that would drive a huge allocation', () {
      // The geometry is attacker-controlled and is multiplied out before
      // the payload is even looked at.
      final huge = ImageLevelPayload(
        ordinal: 0,
        width: 65535,
        height: 65535,
        coderIndex: 0,
        bytes: _bytes(20),
      ).encode();
      expect(ImageLevelPayload.decode(huge), isNull);
    });

    test('refuses an ordinal beyond any real pyramid', () {
      final deep = ImageLevelPayload(
        ordinal: maxImageLevels + 1,
        width: 12,
        height: 12,
        coderIndex: 0,
        bytes: _bytes(4),
      ).encode();
      expect(ImageLevelPayload.decode(deep), isNull);
    });

    test('the ordinal round-trips, because a residual is not a picture', () {
      final decoded = ImageLevelPayload.decode(
        ImageLevelPayload(
          ordinal: 3,
          width: 48,
          height: 36,
          coderIndex: 1,
          bytes: _bytes(8),
        ).encode(),
      );
      expect(decoded!.ordinal, 3);
    });
  });

  group('VoiceTokensPayload', () {
    test('carries its own frame count and row width', () {
      // Supplying the count out of band was a real hazard: a wrong one
      // does not fail, it desynchronizes the shared codec state forever.
      final decoded = VoiceTokensPayload.decode(
        VoiceTokensPayload(
          frameCount: 750,
          rows: 2,
          bytes: _bytes(64),
        ).encode(),
      );
      expect(decoded!.frameCount, 750);
      expect(decoded.rows, 2);
      expect(decoded.bytes.length, 64);
    });

    test('refuses a zero or absurd frame count and row width', () {
      Uint8List encoded(int frames, int rows) => VoiceTokensPayload(
        frameCount: frames,
        rows: rows,
        bytes: _bytes(8),
      ).encode();
      expect(VoiceTokensPayload.decode(encoded(0, 2)), isNull);
      expect(VoiceTokensPayload.decode(encoded(maxVoiceFrames + 1, 2)), isNull);
      expect(VoiceTokensPayload.decode(encoded(10, 0)), isNull);
      expect(VoiceTokensPayload.decode(encoded(10, maxVoiceRows + 1)), isNull);
    });

    test('refuses a truncated header', () {
      expect(VoiceTokensPayload.decode(Uint8List(5)), isNull);
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
