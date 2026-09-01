/// The adapter nobody tested — and the one whose inversion would ship silently.
///
/// `routeAttachment` is ten lines and was, until now, the only production
/// function among the recently-added set with zero coverage. That matters more
/// than its size: it decides which MediaType a payload is judged as, and every
/// threshold downstream is applied to that answer. An inverted mapping here
/// promises a progressive render on a PDF and routes a voice note down the
/// acknowledged path, and neither failure looks like a bug from the outside.
@TestOn('vm')
library;

import 'package:connection_orchestrator/connection_orchestrator.dart';
import 'package:test/test.dart';

void main() {
  group('kind mapping', () {
    test('an image is a photo and everything undeclared is a document', () {
      expect(
        routeAttachment(byteLength: 100, isImage: true).isCliffFree,
        isTrue,
        reason: 'a photo is layerable: it renders coarse before it is whole',
      );
      final doc = routeAttachment(byteLength: 100, isImage: false);
      expect(
        doc.path,
        MediaPath.acknowledged,
        reason: 'a small undeclared attachment has no coarse version',
      );
    });

    test('a voice note is NOT a document', () {
      // The defect this test exists for: a single isImage boolean collapsed
      // audio and video into `document`, so a voice note under the 2 KB text
      // ceiling took the acknowledged path — the exact routing the router was
      // written to prevent.
      final voice = routeAttachment(
        byteLength: 1500,
        isImage: false,
        kind: MediaKindHint.voiceNote,
      );
      expect(voice.isCliffFree, isTrue);
      expect(voice.reason, contains('layerable'));
    });

    test('a video is layerable regardless of size', () {
      expect(
        routeAttachment(
          byteLength: 10,
          isImage: false,
          kind: MediaKindHint.video,
        ).isCliffFree,
        isTrue,
      );
    });

    test('an explicit image hint outranks the legacy boolean', () {
      expect(
        routeAttachment(
          byteLength: 100,
          isImage: false,
          kind: MediaKindHint.image,
        ).isCliffFree,
        isTrue,
      );
    });
  });

  group('loss estimate', () {
    test('above the threshold even small text switches path', () {
      final d = routeAttachment(
        byteLength: 100,
        isImage: false,
        lossEstimate: 0.2,
      );
      expect(d.isCliffFree, isTrue);
      expect(d.reason, contains('round trips'));
    });

    test('at exactly the threshold the cheap path still wins', () {
      expect(
        routeAttachment(
          byteLength: 100,
          isImage: false,
          lossEstimate: 0.10,
        ).path,
        MediaPath.acknowledged,
      );
    });

    test('a NaN or infinite estimate routes as if the link were BAD', () {
      // The worst available failure direction was the silent one: NaN compares
      // false against every threshold, so an unguarded router read "we have no
      // idea" as "the link is clean" and left no trace. An unusable estimate
      // is not evidence of a good link.
      for (final bad in [double.nan, double.infinity, -double.infinity]) {
        final d = routeAttachment(
          byteLength: 100,
          isImage: false,
          lossEstimate: bad,
        );
        expect(d.isCliffFree, isTrue, reason: 'estimate $bad');
        expect(d.reason, contains('not a number'));
      }
    });
  });
}
