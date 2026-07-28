/// Properties for the payload framing, over generated input rather than
/// remembered cases.
///
/// The same two laws as the transport formats: a decode of an encode
/// returns what went in, and no input at all makes a decoder throw. The
/// second matters more here than anywhere else in the workspace, because
/// these decoders run on bytes that arrived from a relay and passed only a
/// hash check — a hash proves the bytes are the ones the author signed, not
/// that they are the ones this build knows how to read.
library;

import 'dart:math';
import 'dart:typed_data';

import 'package:broadcast_media/broadcast_media.dart';
import 'package:test/test.dart';

final Map<String, Object? Function(Uint8List)> _decoders = {
  'envelope': PayloadEnvelope.decode,
  'bundle': PayloadBundle.decode,
  'imageLevel': ImageLevelPayload.decode,
  'videoFrame': VideoFramePayload.decode,
  'voiceTokens': VoiceTokensPayload.decode,
  'spokenText': SpokenTextPlan.decode,
};

Uint8List _randomBytes(Random random, int length) =>
    Uint8List.fromList(List.generate(length, (_) => random.nextInt(256)));

void main() {
  group('no payload decoder throws', () {
    test('on uniformly random bytes', () {
      final random = Random(31);
      for (var trial = 0; trial < 4000; trial++) {
        final bytes = _randomBytes(random, random.nextInt(200));
        for (final entry in _decoders.entries) {
          expect(
            () => entry.value(bytes),
            returnsNormally,
            reason: '${entry.key} threw on ${bytes.length} random bytes',
          );
        }
      }
    });

    test('on bytes shaped like a bundle with hostile length fields', () {
      // The dangerous shape: a valid-looking header whose declared lengths
      // do not match the buffer. Everything a length-prefixed format gets
      // wrong lives here.
      final random = Random(37);
      for (var trial = 0; trial < 3000; trial++) {
        final bytes = _randomBytes(random, 8 + random.nextInt(120));
        bytes[0] = 1;
        final view = ByteData.sublistView(bytes);
        view.setUint16(1, random.nextInt(400));
        if (bytes.length >= 7) {
          view.setUint32(3, random.nextInt(1 << 30));
        }
        for (final entry in _decoders.entries) {
          expect(
            () => entry.value(bytes),
            returnsNormally,
            reason: '${entry.key} threw on a hostile length field',
          );
        }
      }
    });

    test('on every prefix and every bit flip of a real bundle', () {
      final bundle = PayloadBundle([
        PayloadEnvelope(
          kind: PayloadKind.imageLevel,
          body: ImageLevelPayload(
            ordinal: 0,
            width: 24,
            height: 18,
            coderIndex: 0,
            bytes: _randomBytes(Random(41), 30),
          ).encode(),
        ),
        PayloadEnvelope(
          kind: PayloadKind.videoFrame,
          body: VideoFramePayload(
            index: 1,
            predictorIndex: 1,
            bytes: _randomBytes(Random(43), 20),
          ).encode(),
        ),
      ]).encode();

      for (var length = 0; length <= bundle.length; length++) {
        final prefix = Uint8List.fromList(
          Uint8List.sublistView(bundle, 0, length),
        );
        for (final entry in _decoders.entries) {
          expect(
            () => entry.value(prefix),
            returnsNormally,
            reason: '${entry.key} threw on a $length-byte prefix',
          );
        }
      }
      for (var index = 0; index < bundle.length; index++) {
        for (var bit = 0; bit < 8; bit++) {
          final flipped = Uint8List.fromList(bundle)..[index] ^= 1 << bit;
          for (final entry in _decoders.entries) {
            expect(
              () => entry.value(flipped),
              returnsNormally,
              reason: '${entry.key} threw on bit $bit of byte $index',
            );
          }
        }
      }
    });
  });

  group('round trips hold for every generated value', () {
    test('envelope, over every kind and every body length', () {
      final random = Random(47);
      for (var trial = 0; trial < 2000; trial++) {
        final kind =
            PayloadKind.values[random.nextInt(PayloadKind.values.length)];
        final body = _randomBytes(random, random.nextInt(200));
        final decoded = PayloadEnvelope.decode(
          PayloadEnvelope(kind: kind, body: body).encode(),
        );
        expect(decoded, isNotNull, reason: 'trial $trial');
        expect(decoded!.kind, kind);
        expect(decoded.body, body);
      }
    });

    test('bundle, over random part counts and sizes', () {
      final random = Random(53);
      for (var trial = 0; trial < 300; trial++) {
        final parts = [
          for (var i = 0; i < random.nextInt(12); i++)
            PayloadEnvelope(
              kind:
                  PayloadKind.values[random.nextInt(PayloadKind.values.length)],
              body: _randomBytes(random, random.nextInt(80)),
            ),
        ];
        final encoded = PayloadBundle(parts).encode();
        final decoded = PayloadBundle.decode(encoded);
        expect(decoded, isNotNull, reason: 'trial $trial');
        expect(decoded!.parts, hasLength(parts.length));
        for (var i = 0; i < parts.length; i++) {
          expect(decoded.parts[i].kind, parts[i].kind);
          expect(decoded.parts[i].body, parts[i].body);
        }
        // Re-encoding is byte-identical: no hidden state, no padding.
        expect(PayloadBundle(decoded.parts).encode(), encoded);
      }
    });

    test('image level, over the whole accepted geometry range', () {
      final random = Random(59);
      for (var trial = 0; trial < 2000; trial++) {
        final payload = ImageLevelPayload(
          ordinal: random.nextInt(maxImageLevels + 1),
          width: 1 + random.nextInt(maxImageDimension),
          height: 1 + random.nextInt(maxImageDimension),
          coderIndex: random.nextInt(256),
          bytes: _randomBytes(random, 1 + random.nextInt(60)),
        );
        final decoded = ImageLevelPayload.decode(payload.encode());
        expect(decoded, isNotNull, reason: 'trial $trial');
        expect(decoded!.ordinal, payload.ordinal);
        expect(decoded.width, payload.width);
        expect(decoded.height, payload.height);
        expect(decoded.coderIndex, payload.coderIndex);
        expect(decoded.bytes, payload.bytes);
      }
    });

    test('video frame and voice tokens, over their ranges', () {
      final random = Random(61);
      for (var trial = 0; trial < 2000; trial++) {
        final frame = VideoFramePayload(
          index: random.nextInt(0xFFFF),
          predictorIndex: random.nextInt(256),
          bytes: _randomBytes(random, 1 + random.nextInt(60)),
        );
        final decodedFrame = VideoFramePayload.decode(frame.encode());
        expect(decodedFrame!.index, frame.index);
        expect(decodedFrame.predictorIndex, frame.predictorIndex);
        expect(decodedFrame.bytes, frame.bytes);

        final voice = VoiceTokensPayload(
          frameCount: 1 + random.nextInt(maxVoiceFrames),
          rows: 1 + random.nextInt(maxVoiceRows),
          bytes: _randomBytes(random, 1 + random.nextInt(60)),
        );
        final decodedVoice = VoiceTokensPayload.decode(voice.encode());
        expect(decodedVoice!.frameCount, voice.frameCount);
        expect(decodedVoice.rows, voice.rows);
        expect(decodedVoice.bytes, voice.bytes);
      }
    });

    test('spoken text plan, over every legal tag and pace', () {
      final random = Random(67);
      const letters = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ01-';
      for (var trial = 0; trial < 2000; trial++) {
        final tag = String.fromCharCodes([
          for (var i = 0; i < 1 + random.nextInt(maxLanguageTagLength - 1); i++)
            letters.codeUnitAt(random.nextInt(letters.length)),
        ]);
        // The rate is quantized to four, so only multiples round-trip
        // exactly — which is itself the property worth pinning.
        final rate =
            minWordsPerMinute +
            4 * random.nextInt((maxWordsPerMinute - minWordsPerMinute) ~/ 4);
        final plan = SpokenTextPlan(language: tag, wordsPerMinute: rate);
        final decoded = SpokenTextPlan.decode(plan.encode());
        expect(decoded, plan, reason: 'trial $trial with "$tag"');
      }
    });
  });

  test('quantization never moves a pace outside its own bounds', () {
    // A rate that quantized past the ceiling would encode a plan its own
    // decoder refuses — a format that cannot read what it writes.
    for (var rate = minWordsPerMinute; rate <= maxWordsPerMinute; rate++) {
      final plan = SpokenTextPlan(language: 'fa', wordsPerMinute: rate);
      final decoded = SpokenTextPlan.decode(plan.encode());
      expect(decoded, isNotNull, reason: 'rate $rate must round-trip');
      expect(
        decoded!.wordsPerMinute,
        inInclusiveRange(minWordsPerMinute, maxWordsPerMinute),
      );
      expect((decoded.wordsPerMinute - rate).abs(), lessThanOrEqualTo(4));
    }
  });
}
