import 'dart:typed_data';

import 'package:device_link/device_link.dart';
import 'package:test/test.dart';

/// Fake authenticator: does not implement real crypto. [verifyResult]
/// controls pass/fail and [createForwardedEnvelope] mints a hop-incremented
/// copy, matching the documented adapter contract.
class FakeMediaFrameAuthenticator implements MediaFrameAuthenticator {
  bool verifyResult = true;
  final List<MediaFrame> verifyCalls = [];

  /// When true, [createForwardedEnvelope] returns a frame that violates the
  /// forwarding-transition contract (hop count not incremented), so the
  /// processor's integrity check is exercised.
  bool produceInvalidTransition = false;

  @override
  Future<bool> verify(MediaFrame envelope) async {
    verifyCalls.add(envelope);
    return verifyResult;
  }

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
      hopCount: produceInvalidTransition
          ? envelope.hopCount
          : envelope.hopCount + 1,
      ciphertext: envelope.ciphertext,
      signature: envelope.signature,
    );
  }
}

class FakeLinkBroadcaster implements LinkBroadcaster {
  final List<MediaFrame> broadcasted = [];

  @override
  Future<void> broadcast(MediaFrame envelope) async {
    broadcasted.add(envelope);
  }
}

MediaFrame _frame({
  String messageId = 'msg-1',
  String originKeyId = 'origin-a',
  String currentRelayKeyId = 'relay-a',
  int createdAtMs = 1000000,
  int expiresAtMs = 1060000,
  int maxHops = 3,
  int hopCount = 0,
}) {
  return MediaFrame(
    messageId: messageId,
    originKeyId: originKeyId,
    currentRelayKeyId: currentRelayKeyId,
    createdAtMs: createdAtMs,
    expiresAtMs: expiresAtMs,
    maxHops: maxHops,
    hopCount: hopCount,
    ciphertext: Uint8List.fromList([1, 2, 3]),
    signature: Uint8List.fromList([9, 9, 9]),
  );
}

void main() {
  group('LinkMessageProcessor', () {
    late FakeMediaFrameAuthenticator authenticator;
    late FakeLinkBroadcaster broadcaster;
    late LinkSeenCache seenCache;
    late List<MediaFrame> delivered;
    const nowMs = 1000000;

    LinkMessageProcessor buildProcessor({bool forwardingEnabled = false}) {
      return LinkMessageProcessor(
        authenticator: authenticator,
        broadcaster: broadcaster,
        seenCache: seenCache,
        forwardingEnabled: forwardingEnabled,
        onDeliver: (envelope) async {
          delivered.add(envelope);
        },
      );
    }

    setUp(() {
      authenticator = FakeMediaFrameAuthenticator();
      broadcaster = FakeLinkBroadcaster();
      seenCache = LinkSeenCache();
      delivered = [];
    });

    test('a duplicate messageId is not reprocessed or redelivered', () async {
      final processor = buildProcessor();
      final frame = _frame(messageId: 'dup-1');

      final first = await processor.process(frame, nowMs: nowMs);
      final second = await processor.process(frame, nowMs: nowMs + 10);

      expect(first, LinkDisposition.delivered);
      expect(second, LinkDisposition.duplicate);
      expect(delivered, hasLength(1));
    });

    test('an expired frame is dropped before delivery', () async {
      final processor = buildProcessor();
      final frame = _frame(
        createdAtMs: nowMs - 5000,
        expiresAtMs: nowMs - 1000,
      );

      final result = await processor.process(frame, nowMs: nowMs);

      expect(result, LinkDisposition.expired);
      expect(delivered, isEmpty);
    });

    test('a hop count exceeding maxHops is dropped as an invalid frame, '
        'before signature verification is even attempted', () async {
      final processor = buildProcessor();
      final frame = _frame(maxHops: 3, hopCount: 4);

      final result = await processor.process(frame, nowMs: nowMs);

      expect(result, LinkDisposition.rejected);
      expect(delivered, isEmpty);
      expect(authenticator.verifyCalls, isEmpty);
    });

    test('forwarding is disabled by default: the frame is delivered but never '
        'broadcast', () async {
      final processor = buildProcessor(); // forwardingEnabled: false
      final frame = _frame(messageId: 'no-forward-1', maxHops: 3, hopCount: 0);

      final result = await processor.process(frame, nowMs: nowMs);

      expect(result, LinkDisposition.delivered);
      expect(delivered, hasLength(1));
      expect(broadcaster.broadcasted, isEmpty);
    });

    test('forwarding enabled + hop limit already reached: delivered but not '
        'broadcast', () async {
      final processor = buildProcessor(forwardingEnabled: true);
      final frame = _frame(messageId: 'hop-limit-1', maxHops: 2, hopCount: 2);

      final result = await processor.process(frame, nowMs: nowMs);

      expect(result, LinkDisposition.hopLimitReached);
      expect(delivered, hasLength(1));
      expect(broadcaster.broadcasted, isEmpty);
    });

    test('forwarding enabled + within hop limit: delivered and broadcast with '
        'an incremented hop count', () async {
      final processor = buildProcessor(forwardingEnabled: true);
      final frame = _frame(messageId: 'forward-1', maxHops: 3, hopCount: 0);

      final result = await processor.process(frame, nowMs: nowMs);

      expect(result, LinkDisposition.deliveredAndForwarded);
      expect(delivered, hasLength(1));
      expect(broadcaster.broadcasted, hasLength(1));
      expect(broadcaster.broadcasted.single.hopCount, 1);
    });

    test('forwarding enabled + authenticator produces an invalid transition: '
        'processor throws', () async {
      authenticator.produceInvalidTransition = true;
      final processor = buildProcessor(forwardingEnabled: true);
      final frame = _frame(messageId: 'forward-bad-1', maxHops: 3, hopCount: 0);

      await expectLater(
        processor.process(frame, nowMs: nowMs),
        throwsA(isA<StateError>()),
      );
      expect(broadcaster.broadcasted, isEmpty);
    });
  });

  group('generateLinkMessageId', () {
    test('produces non-empty, distinct ids across calls', () {
      final a = generateLinkMessageId();
      final b = generateLinkMessageId();

      expect(a, isNotEmpty);
      expect(b, isNotEmpty);
      expect(a, isNot(equals(b)));
    });
  });

  group('LinkSeenCache', () {
    test('inserting beyond maximumEntries evicts the oldest entry '
        '(FIFO by insertion order)', () {
      final cache = LinkSeenCache(maximumEntries: 2);
      const nowMs = 1000000;
      const farExpiry = nowMs + 60000;

      expect(
        cache.markIfNew(messageId: 'a', expiresAtMs: farExpiry, nowMs: nowMs),
        isTrue,
      );
      expect(
        cache.markIfNew(messageId: 'b', expiresAtMs: farExpiry, nowMs: nowMs),
        isTrue,
      );
      // Inserting a third entry over the cap evicts 'a', the oldest.
      expect(
        cache.markIfNew(messageId: 'c', expiresAtMs: farExpiry, nowMs: nowMs),
        isTrue,
      );

      // 'a' was evicted to make room for 'c': it is new again.
      expect(
        cache.markIfNew(messageId: 'a', expiresAtMs: farExpiry, nowMs: nowMs),
        isTrue,
      );
      // 'c' was never evicted: still tracked as seen.
      expect(
        cache.markIfNew(messageId: 'c', expiresAtMs: farExpiry, nowMs: nowMs),
        isFalse,
      );
    });

    test('an entry whose expiry has passed is purged on the next call and can '
        'be re-added as new', () {
      final cache = LinkSeenCache();
      const nowMs = 1000000;

      expect(
        cache.markIfNew(messageId: 'a', expiresAtMs: nowMs + 50, nowMs: nowMs),
        isTrue,
      );

      // A later call (for a different id) purges 'a' because its expiry
      // has now passed.
      final laterNowMs = nowMs + 200;
      expect(
        cache.markIfNew(
          messageId: 'b',
          expiresAtMs: laterNowMs + 60000,
          nowMs: laterNowMs,
        ),
        isTrue,
      );

      // 'a' was purged for being expired, not merely capacity-evicted:
      // it is treated as new again.
      expect(
        cache.markIfNew(
          messageId: 'a',
          expiresAtMs: laterNowMs + 60000,
          nowMs: laterNowMs,
        ),
        isTrue,
      );
    });
  });
}
