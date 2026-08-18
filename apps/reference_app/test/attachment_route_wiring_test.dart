/// The advisor that runs on every real attachment send — and could kill it.
///
/// This file had no test, and the defect it hides is the nastiest kind:
/// observability code that can lose a user's photo. The advisor executes
/// SYNCHRONOUSLY inside `startAttachmentSend`, before the handle exists, and it
/// calls two closures it does not own — `lossEstimate` (someone's estimator)
/// and `onDecision` (wired in the app to `notifyListeners`, which throws on a
/// disposed ChangeNotifier). An exception from either used to propagate out of
/// a method named "start", and the attachment was never sent.
@TestOn('vm')
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:messaging/messaging.dart';
import 'package:reference_app/src/attachment_route_wiring.dart';

void main() {
  group('the advisor cannot break the send', () {
    test('a throwing onDecision still yields a decision', () {
      final advisor = buildAttachmentRouteAdvisor(
        onDecision: (_) => throw StateError('notifyListeners after dispose'),
      );
      final decision = advisor(byteLength: 4096, isImage: true);
      expect(decision, isNotNull);
      expect(decision!.wouldUseCliffFree, isTrue);
    });

    test('a throwing lossEstimate yields null rather than an exception', () {
      final advisor = buildAttachmentRouteAdvisor(
        lossEstimate: () => throw StateError('estimator exploded'),
      );
      // No decision is a truthful answer. A wrong decision is not, and an
      // exception here means no attachment at all.
      expect(() => advisor(byteLength: 100, isImage: false), returnsNormally);
      expect(advisor(byteLength: 100, isImage: false), isNull);
    });

    test('a non-finite estimate reaches the router, which routes it as BAD',
        () {
      // This test used to assert `lossEstimate.isFinite`, and passing it was
      // the bug: the only way to satisfy that here was to substitute 0.0
      // BEFORE the router saw the value, which deleted the router's non-finite
      // guard from the outside. Clamping [0,1] and erasing NaN look like the
      // same line of code and are opposite decisions.
      for (final bad in [double.nan, double.infinity, -double.infinity]) {
        AttachmentRouteDecision? seen;
        final advisor = buildAttachmentRouteAdvisor(
          lossEstimate: () => bad,
          onDecision: (d) => seen = d,
        );
        // 100 B of non-image would take the ACKNOWLEDGED path on a clean link.
        final decision = advisor(byteLength: 100, isImage: false)!;
        expect(decision.wouldUseCliffFree, isTrue, reason: 'estimate $bad');
        expect(decision.reason, contains('not a number'));
        expect(seen, isNotNull);

        // Two things must survive a non-finite value rather than throw:
        // a diagnostic that throws turns one incident into two, and a
        // telemetry map that cannot be encoded is an event that never ships.
        expect(decision.toString(), contains('unknown'));
        expect(decision.toTelemetry()['lossEstimate'], isNull);
        expect(() => jsonEncode(decision.toTelemetry()), returnsNormally);
      }
    });

    test('an out-of-range estimate is clamped to [0, 1]', () {
      final high = buildAttachmentRouteAdvisor(lossEstimate: () => 7.5)(
        byteLength: 100,
        isImage: false,
      )!;
      final low = buildAttachmentRouteAdvisor(lossEstimate: () => -3.0)(
        byteLength: 100,
        isImage: false,
      )!;
      expect(high.lossEstimate, 1.0);
      expect(low.lossEstimate, 0.0);
    });
  });

  group('what the decision reports', () {
    test('shadow mode: never claims a path the send did not take', () {
      // There is no obeyDecision flag any more, and this is why: it set
      // actuallyUsedCliffFree while the send path was unconditionally the
      // acknowledged one, producing telemetry that lied on the single metric
      // shadow mode exists to produce.
      final advisor = buildAttachmentRouteAdvisor();
      for (final isImage in [true, false]) {
        final d = advisor(byteLength: 50 * 1024, isImage: isImage)!;
        expect(
          d.actuallyUsedCliffFree,
          isFalse,
          reason: 'the send path has not switched yet, so nothing may say it '
              'did',
        );
      }
    });

    test('isShadowed marks exactly the cases that would differ', () {
      final advisor = buildAttachmentRouteAdvisor();
      final photo = advisor(byteLength: 50 * 1024, isImage: true)!;
      final smallText = advisor(byteLength: 100, isImage: false)!;

      expect(photo.wouldUseCliffFree, isTrue);
      expect(photo.isShadowed, isTrue);
      expect(smallText.wouldUseCliffFree, isFalse);
      expect(
        smallText.isShadowed,
        isFalse,
        reason: 'the acknowledged path is what actually happens, so this row '
            'is not a deferred decision',
      );
    });

    test('the reason travels with the decision', () {
      final d = buildAttachmentRouteAdvisor()(
        byteLength: 64 * 1024,
        isImage: false,
      )!;
      expect(d.reason, isNotEmpty);
      expect(d.toTelemetry()['reason'], d.reason);
    });

    test('a negative byte length is floored rather than routed on', () {
      final d = buildAttachmentRouteAdvisor()(byteLength: -1, isImage: false);
      expect(d, isNotNull);
      expect(d!.byteLength, -1, reason: 'reported verbatim for diagnosis');
    });
  });
}
