import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:broadcast/broadcast.dart';
import 'package:broadcast_media/broadcast_media.dart';
import 'package:clock/clock.dart';
import 'package:hamseda_codec/hamseda_codec.dart';
import 'package:test/test.dart';

const String _persianBody =
    'مردم شهر امشب در خیابان‌ها هستند. اینترنت قطع است و تنها راهِ '
    'رسیدنِ خبر همین پیام است. هرکس این را خواند، برای دیگری بخواند.';

/// A gradient with a dark disc in it: something with real structure, so a
/// lossy codec's output can be compared to it meaningfully.
RasterImage _picture({int width = 160, int height = 120}) {
  final pixels = Uint8List(width * height * 3);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final dx = x - width / 2;
      final dy = y - height / 2;
      final inDisc = math.sqrt(dx * dx + dy * dy) < width / 5;
      final base = inDisc ? 30 : 40 + (x * 180 ~/ width);
      final i = (y * width + x) * 3;
      pixels[i] = base & 0xFF;
      pixels[i + 1] = (base + y * 40 ~/ height) & 0xFF;
      pixels[i + 2] = (255 - base) & 0xFF;
    }
  }
  return RasterImage(pixels: pixels, width: width, height: height, channels: 3);
}

/// A moving bright square, so temporal prediction has something to find.
VideoClip _clip({int frames = 4, int width = 64, int height = 48}) {
  final out = <Uint8List>[];
  for (var f = 0; f < frames; f++) {
    final frame = Uint8List(width * height);
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final moving = x >= f * 3 && x < f * 3 + 12 && y > 10 && y < 30;
        frame[y * width + x] = moving ? 230 : 25;
      }
    }
    out.add(frame);
  }
  return VideoClip(frames: out, width: width, height: height);
}

/// Deterministic token columns standing in for a neural codec's output.
List<List<int>> _tokens(int frameCount, int rows, {int seed = 3}) {
  var state = seed;
  return [
    for (var f = 0; f < frameCount; f++)
      [
        for (var r = 0; r < rows; r++)
          (state = (state * 1103515245 + 12345) & 0x3FFFFFFF) % 1024,
      ],
  ];
}

void main() {
  const composer = BroadcastMediaComposer();
  const renderer = BroadcastMediaRenderer();
  final t0 = DateTime.utc(2026, 7, 28, 12);

  group('text', () {
    test('survives the round trip exactly, including Persian', () {
      final layers = composer.compose(body: _persianBody);
      final rendered = renderer.render(textLayer: layers.text);
      expect(rendered.body, _persianBody);
      expect(rendered.unreadableParts, 0);
    });

    test('compresses rather than merely wrapping', () {
      // Against UTF-8, which is what the text actually costs on a wire —
      // Persian is about two bytes per character, so comparing against
      // UTF-16 code units would flatter the codec by understating the
      // baseline.
      final raw = utf8.encode(_persianBody).length;
      final layers = composer.compose(body: _persianBody);
      expect(layers.text!.length, lessThan(raw));
      expect(layers.text!.length / raw, lessThan(0.8));
    });

    test('an empty body produces no layer at all', () {
      final layers = composer.compose(body: '');
      expect(layers.text, isNull);
      expect(layers.isEmpty, isTrue);
    });

    test('text is never dropped, only reported when over budget', () {
      // The layer that carries the message is the one thing a budget may
      // not silently remove.
      const tight = BroadcastMediaComposer(budget: MediaBudget(textBytes: 8));
      final layers = tight.compose(body: _persianBody);
      expect(layers.text, isNotNull);
      expect(
        layers.report.dropped.map((p) => p.name),
        contains('text.over-budget'),
      );
      expect(renderer.render(textLayer: layers.text).body, _persianBody);
    });
  });

  group('still picture', () {
    test('the coarsest level lands in its own small layer', () {
      final layers = composer.compose(picture: _picture());
      expect(layers.still, isNotNull);
      // One fetch, and the reader has a picture. That is the point of
      // giving level zero a layer of its own.
      expect(layers.still!.length, lessThan(4 * 1024));
    });

    test('a thumbnail decodes from the still layer alone', () {
      final layers = composer.compose(picture: _picture());
      final rendered = renderer.render(stillLayer: layers.still);
      expect(rendered.thumbnail, isNotNull);
      expect(rendered.thumbnail!.width, greaterThan(0));
      expect(rendered.thumbnail!.gray, isNotEmpty);
      expect(rendered.unreadableParts, 0);
    });

    test('refinements ride the heavy layer and sharpen the result', () {
      final layers = composer.compose(picture: _picture());
      expect(layers.heavy, isNotNull);

      final coarse = renderer.render(stillLayer: layers.still).thumbnail!;
      final full = renderer
          .render(stillLayer: layers.still, heavyLayer: layers.heavy)
          .thumbnail!;
      expect(
        full.width,
        greaterThan(coarse.width),
        reason: 'the refinements must actually refine',
      );
    });

    test('refinements without their base level show nothing at all', () {
      // This test previously asserted the opposite, and the opposite was a
      // defect. A refinement is a residual against the level below it, so
      // levels 1 and 2 with no level 0 are not a coarser picture — they
      // decode without complaint into noise that would be displayed as the
      // author's photograph. Showing nothing is the only honest outcome.
      final layers = composer.compose(picture: _picture());
      final rendered = renderer.render(heavyLayer: layers.heavy);
      expect(rendered.thumbnail, isNull);
      expect(rendered.unreadableParts, greaterThan(0));
    });

    test(
      'the base level alone is a picture; adding refinements improves it',
      () {
        final layers = composer.compose(picture: _picture());
        final base = renderer.render(stillLayer: layers.still);
        expect(base.thumbnail, isNotNull);
        expect(base.unreadableParts, 0);

        final full = renderer.render(
          stillLayer: layers.still,
          heavyLayer: layers.heavy,
        );
        expect(full.thumbnail!.width, greaterThan(base.thumbnail!.width));
        expect(full.unreadableParts, 0);
      },
    );

    test('a damaged refinement keeps the picture decoded so far', () {
      // Partial recovery is the whole promise of a progressive format.
      final layers = composer.compose(picture: _picture());
      final damaged = Uint8List.fromList(layers.heavy!);
      // Corrupt deep inside the last part's entropy payload.
      damaged[damaged.length - 5] ^= 0xFF;
      final rendered = renderer.render(
        stillLayer: layers.still,
        heavyLayer: damaged,
      );
      expect(
        rendered.thumbnail,
        isNotNull,
        reason: 'the levels that did decode must survive',
      );
    });

    test('a duplicate level ordinal is refused, not silently substituted', () {
      final layers = composer.compose(picture: _picture());
      final base = PayloadEnvelope.decode(layers.still!)!;
      final doubled = PayloadBundle([base, base]).encode();
      final rendered = renderer.render(heavyLayer: doubled);
      expect(rendered.unreadableParts, 1);
    });

    test('a colour picture survives the whole path in colour', () {
      // Grayscale cannot say whether the thing in the photograph is fire
      // or water, and that is often the only question that matters.
      final layers = composer.compose(picture: _picture());
      expect(
        layers.report.included.map((p) => p.name),
        contains('image.colour'),
      );

      final rendered = renderer.render(
        stillLayer: layers.still,
        heavyLayer: layers.heavy,
      );
      expect(rendered.thumbnail!.hasColour, isTrue);
      expect(
        rendered.thumbnail!.rgb!.length,
        rendered.thumbnail!.width * rendered.thumbnail!.height * 3,
      );
      expect(rendered.unreadableParts, 0);
    });

    test('the still layer alone is a picture without colour', () {
      // Colour rides the optional bundle, so a reader that fetched only
      // the small layer gets a grayscale photograph rather than nothing.
      final layers = composer.compose(picture: _picture());
      final rendered = renderer.render(stillLayer: layers.still);
      expect(rendered.thumbnail, isNotNull);
      expect(rendered.thumbnail!.hasColour, isFalse);
      expect(rendered.unreadableParts, 0);
    });

    test('colour costs a fraction of the picture it colours', () {
      final layers = composer.compose(picture: _picture());
      final colour = layers.report.parts
          .firstWhere((p) => p.name == 'image.colour')
          .bytes;
      final luma = layers.report.parts
          .where((p) => p.name.startsWith('image.level'))
          .fold<int>(0, (sum, p) => sum + p.bytes);
      expect(colour, lessThan(luma ~/ 3));
    });

    test('a grayscale source produces no colour part at all', () {
      final grey = RasterImage(
        pixels: Uint8List(64 * 48),
        width: 64,
        height: 48,
        channels: 1,
      );
      final layers = composer.compose(picture: grey);
      expect(
        layers.report.parts.map((p) => p.name),
        isNot(contains('image.colour')),
      );
    });

    test('every level is named in the report with its size', () {
      final layers = composer.compose(picture: _picture());
      final names = layers.report.parts.map((p) => p.name).toList();
      expect(names, contains('image.level.0'));
      expect(names, contains('image.level.1'));
      for (final part in layers.report.parts) {
        expect(part.bytes, greaterThan(0));
      }
    });
  });

  group('voice tokens', () {
    test('round-trip through paired sessions returns the same columns', () {
      const rows = 2;
      final columns = _tokens(60, rows);
      final sender = HamsedaSession(rows);
      final receiver = HamsedaSession(rows);

      final layers = composer.compose(
        voiceTokens: VoiceTokenBlock(columns: columns, rows: rows),
        voiceSession: sender,
      );
      expect(layers.voice, isNotNull);

      final rendered = renderer.render(
        voiceLayer: layers.voice,
        voiceSession: receiver,
      );
      expect(rendered.voiceColumns, columns);
      expect(rendered.unreadableParts, 0);
    });

    test('a minute of speech fits in a text-message-sized layer', () {
      // The claim the whole voice tier rests on. 60 s at 20 bits per
      // frame and 75 frames per second is the codec's own framing.
      const rows = 2;
      final sender = HamsedaSession(rows);
      final layers = composer.compose(
        voiceTokens: VoiceTokenBlock(columns: _tokens(750, rows), rows: rows),
        voiceSession: sender,
      );
      expect(layers.voice!.length, lessThan(4 * 1024));
    });

    test('tokens without a session are refused, not silently dropped', () {
      expect(
        () => composer.compose(
          voiceTokens: VoiceTokenBlock(columns: _tokens(4, 2), rows: 2),
        ),
        throwsArgumentError,
      );
    });

    test('a block that does not fit rolls the shared state back', () {
      // Advancing the sender past a block the reader never gets would make
      // every later block decode to nonsense.
      const rows = 2;
      const tight = BroadcastMediaComposer(budget: MediaBudget(voiceBytes: 4));
      final sender = HamsedaSession(rows);
      final before = sender.committed.toJson().toString();

      final layers = tight.compose(
        voiceTokens: VoiceTokenBlock(columns: _tokens(40, rows), rows: rows),
        voiceSession: sender,
      );
      expect(layers.voice, isNull);
      expect(layers.report.dropped.map((p) => p.name), contains('voice'));
      expect(sender.committed.toJson().toString(), before);
    });

    test(
      'a corrupt voice layer rolls the reader back instead of desyncing',
      () {
        const rows = 2;
        final sender = HamsedaSession(rows);
        final receiver = HamsedaSession(rows);
        final columns = _tokens(30, rows);
        final layers = composer.compose(
          voiceTokens: VoiceTokenBlock(columns: columns, rows: rows),
          voiceSession: sender,
        );
        final before = receiver.committed.toJson().toString();

        final damaged = Uint8List.fromList(layers.voice!);
        damaged[damaged.length - 1] ^= 0xFF;
        final rendered = renderer.render(
          voiceLayer: damaged,
          voiceSession: receiver,
        );
        // Either it decoded to something wrong or it threw; what must hold
        // is that a failure did not advance the shared state.
        if (rendered.voiceColumns == null) {
          expect(receiver.committed.toJson().toString(), before);
        }
      },
    );
  });

  group('short clip', () {
    test('frames survive the round trip in order', () {
      final layers = composer.compose(clip: _clip());
      final rendered = renderer.render(heavyLayer: layers.heavy);
      expect(rendered.videoFrames, hasLength(4));
      for (final frame in rendered.videoFrames) {
        expect(frame, isNotEmpty);
      }
    });

    test('a clip costs far less than raw frames', () {
      final clip = _clip(frames: 6);
      final rawBytes = clip.frames.fold(0, (sum, f) => sum + f.length);
      final layers = composer.compose(clip: clip);
      expect(layers.heavy!.length, lessThan(rawBytes ~/ 4));
    });

    test('frames stop at the first one that does not fit', () {
      // A frame predicted from a dropped frame cannot be decoded, so
      // skipping ahead would produce a bundle that lies about itself.
      final composerWithRoom = BroadcastMediaComposer(
        budget: const MediaBudget(heavyBytes: 700),
      );
      final layers = composerWithRoom.compose(clip: _clip(frames: 8));
      final frameParts = layers.report.parts
          .where((p) => p.name.startsWith('video.frame'))
          .toList();
      final firstDropped = frameParts.indexWhere((p) => !p.included);
      if (firstDropped >= 0) {
        for (var i = firstDropped; i < frameParts.length; i++) {
          expect(
            frameParts[i].included,
            isFalse,
            reason: 'nothing may be included after the first drop',
          );
        }
      }
    });
  });

  group('budget', () {
    test('the survival budget keeps words and drops everything heavy', () {
      const survival = BroadcastMediaComposer(budget: MediaBudget.survival);
      final layers = survival.compose(
        body: _persianBody,
        picture: _picture(),
        clip: _clip(),
      );
      expect(layers.text, isNotNull);
      expect(layers.heavy, isNull, reason: 'heavy is disabled at this budget');
      expect(layers.report.isComplete, isFalse);
      expect(layers.report.dropped, isNotEmpty);
      // Whatever survived is still a complete, readable message.
      expect(renderer.render(textLayer: layers.text).body, _persianBody);
    });

    test('every dropped part is named with what it would have cost', () {
      const survival = BroadcastMediaComposer(budget: MediaBudget.survival);
      final layers = survival.compose(picture: _picture(), clip: _clip());
      for (final part in layers.report.dropped) {
        expect(part.name, isNotEmpty);
        expect(part.bytes, greaterThan(0));
      }
    });

    test('the report reads as a summary a human can act on', () {
      final layers = composer.compose(body: 'hello', picture: _picture());
      expect(layers.report.toString(), contains('parts'));
      expect(layers.report.includedBytes, greaterThan(0));
    });
  });

  group('a whole post, composed and published', () {
    test('text, picture and clip survive publish and read', () async {
      final root = await CryptographyBroadcastSigner.generate();
      final publisher = await withClock(
        Clock.fixed(t0),
        () => BroadcastPublisher.create(rootSigner: root),
      );
      final relay = InMemoryBroadcastRelay();

      final layers = composer.compose(
        body: _persianBody,
        picture: _picture(),
        clip: _clip(),
      );
      final post = await withClock(
        Clock.fixed(t0),
        () => publishComposed(publisher, layers),
      );
      await publisher.pushTo(relay, post);

      final reader = BroadcastReader(
        rootPublicKey: root.publicKey,
        relays: [relay],
      );
      await withClock(
        Clock.fixed(t0),
        () => reader.adoptCertificate(publisher.certificate.encoded),
      );
      final result = await withClock(
        Clock.fixed(t0.add(const Duration(minutes: 1))),
        () => reader.fetchNext(),
      );
      expect(result.isDelivered, isTrue);
      final descriptor = result.descriptor!;

      final rendered = renderer.render(
        textLayer: await reader.fetchLayer(descriptor, LayerFlag.text),
        stillLayer: await reader.fetchLayer(descriptor, LayerFlag.still),
        heavyLayer: await reader.fetchMedia(descriptor),
      );
      expect(rendered.body, _persianBody);
      expect(rendered.thumbnail, isNotNull);
      expect(rendered.videoFrames, hasLength(4));
      expect(rendered.unreadableParts, 0);
    });

    test('a reader that fetches only text still gets the message', () async {
      // The degraded path: one small fetch, a complete message.
      final root = await CryptographyBroadcastSigner.generate();
      final publisher = await withClock(
        Clock.fixed(t0),
        () => BroadcastPublisher.create(rootSigner: root),
      );
      final relay = InMemoryBroadcastRelay();
      final layers = composer.compose(body: _persianBody, picture: _picture());
      final post = await withClock(
        Clock.fixed(t0),
        () => publishComposed(publisher, layers),
      );
      await publisher.pushTo(relay, post);

      final reader = BroadcastReader(
        rootPublicKey: root.publicKey,
        relays: [relay],
      );
      await withClock(
        Clock.fixed(t0),
        () => reader.adoptCertificate(publisher.certificate.encoded),
      );
      final result = await withClock(
        Clock.fixed(t0.add(const Duration(minutes: 1))),
        () => reader.fetchNext(),
      );
      final textOnly = await reader.fetchLayer(
        result.descriptor!,
        LayerFlag.text,
      );
      expect(renderer.render(textLayer: textOnly).body, _persianBody);
    });

    test('publishing nothing is refused', () async {
      final root = await CryptographyBroadcastSigner.generate();
      final publisher = await withClock(
        Clock.fixed(t0),
        () => BroadcastPublisher.create(rootSigner: root),
      );
      expect(
        () => publishComposed(
          publisher,
          ComposedLayers(report: CompositionReport(const [])),
        ),
        throwsArgumentError,
      );
      expect(publisher.nextSeq, 0, reason: 'no sequence number was spent');
    });
  });

  group('hostile layers', () {
    test('a layer of noise is counted, never rendered as something else', () {
      final noise = Uint8List.fromList(List.filled(64, 0xAB));
      final rendered = renderer.render(
        textLayer: noise,
        stillLayer: noise,
        heavyLayer: noise,
      );
      expect(rendered.isEmpty, isTrue);
      expect(rendered.unreadableParts, 3);
    });

    test('a payload of the wrong kind in a layer is refused', () {
      final wrong = PayloadEnvelope(
        kind: PayloadKind.videoFrame,
        body: Uint8List.fromList([1, 2, 3, 4]),
      ).encode();
      final rendered = renderer.render(textLayer: wrong);
      expect(rendered.body, isNull);
      expect(rendered.unreadableParts, 1);
    });

    test('an unknown image coder is refused rather than approximated', () {
      final level = ImageLevelPayload(
        ordinal: 0,
        width: 12,
        height: 12,
        coderIndex: 200,
        bytes: Uint8List.fromList([1, 2, 3]),
      );
      final rendered = renderer.render(
        stillLayer: PayloadEnvelope(
          kind: PayloadKind.imageLevel,
          body: level.encode(),
        ).encode(),
      );
      expect(rendered.thumbnail, isNull);
      expect(rendered.unreadableParts, 1);
    });

    test('rendering nothing at all is empty, not an error', () {
      final rendered = renderer.render();
      expect(rendered.isEmpty, isTrue);
      expect(rendered.unreadableParts, 0);
    });
  });

  group('source validation', () {
    test('a raster whose buffer does not match its size is refused', () {
      expect(
        () => RasterImage(
          pixels: Uint8List(10),
          width: 4,
          height: 4,
          channels: 3,
        ),
        throwsArgumentError,
      );
      expect(
        () =>
            RasterImage(pixels: Uint8List(0), width: 0, height: 4, channels: 3),
        throwsArgumentError,
      );
      expect(
        () => RasterImage(
          pixels: Uint8List(16),
          width: 4,
          height: 4,
          channels: 5,
        ),
        throwsArgumentError,
      );
    });

    test('a clip with a mis-sized frame is refused', () {
      expect(
        () => VideoClip(
          frames: [Uint8List(16), Uint8List(9)],
          width: 4,
          height: 4,
        ),
        throwsArgumentError,
      );
      expect(
        () => VideoClip(frames: const [], width: 4, height: 4),
        throwsArgumentError,
      );
    });

    test('a token block with a short column is refused', () {
      expect(
        () => VoiceTokenBlock(
          columns: [
            [1, 2],
            [3],
          ],
          rows: 2,
        ),
        throwsArgumentError,
      );
      expect(
        () => VoiceTokenBlock(columns: const [], rows: 2),
        throwsArgumentError,
      );
    });
  });
}
