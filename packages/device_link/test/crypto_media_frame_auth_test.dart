import 'dart:convert';

import 'package:device_link/device_link.dart';
import 'package:test/test.dart';

class _RecordingBroadcaster implements LinkBroadcaster {
  final List<MediaFrame> broadcasted = [];

  @override
  Future<void> broadcast(MediaFrame envelope) async {
    broadcasted.add(envelope);
  }
}

void main() {
  group('CryptoMediaFrameAuthenticator over LinkMessageProcessor', () {
    const nowMs = 1000000;

    late CryptoEnvelopeSigner originSigner;
    late CryptoEnvelopeSigner relaySigner;
    late CryptoEnvelopeVerifier verifier;
    late CryptoMediaFrameAuthenticator originAuthenticator;
    late CryptoMediaFrameAuthenticator relayAuthenticator;
    late _RecordingBroadcaster broadcaster;
    late LinkSeenCache seenCache;
    late List<MediaFrame> delivered;

    setUp(() async {
      originSigner = await CryptoEnvelopeSigner.generate(keyId: 'origin-1');
      relaySigner = await CryptoEnvelopeSigner.generate(keyId: 'relay-1');
      verifier = CryptoEnvelopeVerifier();
      verifier.trust('origin-1', await originSigner.extractPublicKey());
      verifier.trust('relay-1', await relaySigner.extractPublicKey());
      originAuthenticator = CryptoMediaFrameAuthenticator(
        signer: originSigner,
        verifier: verifier,
      );
      relayAuthenticator = CryptoMediaFrameAuthenticator(
        signer: relaySigner,
        verifier: verifier,
      );
      broadcaster = _RecordingBroadcaster();
      seenCache = LinkSeenCache();
      delivered = [];
    });

    LinkMessageProcessor buildProcessor({
      required CryptoMediaFrameAuthenticator authenticator,
      bool forwardingEnabled = false,
    }) {
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

    Future<MediaFrame> originFrame({
      String messageId = 'msg-1',
      int maxHops = 3,
      int hopCount = 0,
      List<int>? ciphertext,
    }) => CryptoMediaFrameAuthenticator.createOriginFrame(
      signer: originSigner,
      messageId: messageId,
      ciphertext: ciphertext ?? utf8.encode('ciphertext bytes'),
      createdAtMs: nowMs,
      expiresAtMs: nowMs + 60000,
      maxHops: maxHops,
    );

    test('a validly-signed origin frame verifies and is delivered exactly '
        'once (duplicate deliveries are deduped)', () async {
      final processor = buildProcessor(authenticator: originAuthenticator);
      final frame = await originFrame(messageId: 'dedup-1');

      final first = await processor.process(frame, nowMs: nowMs);
      final second = await processor.process(frame, nowMs: nowMs + 10);

      expect(first, LinkDisposition.delivered);
      expect(second, LinkDisposition.duplicate);
      expect(delivered, hasLength(1));
    });

    test(
      'a tampered ciphertext (signature unchanged) fails verification',
      () async {
        final processor = buildProcessor(authenticator: originAuthenticator);
        final frame = await originFrame(messageId: 'tamper-1');
        final tampered = MediaFrame(
          version: frame.version,
          messageId: frame.messageId,
          originKeyId: frame.originKeyId,
          currentRelayKeyId: frame.currentRelayKeyId,
          createdAtMs: frame.createdAtMs,
          expiresAtMs: frame.expiresAtMs,
          maxHops: frame.maxHops,
          hopCount: frame.hopCount,
          ciphertext: utf8.encode('different ciphertext bytes!'),
          signature: frame.signature,
        );

        final result = await processor.process(tampered, nowMs: nowMs);

        expect(result, LinkDisposition.invalid);
        expect(delivered, isEmpty);
      },
    );

    test(
      'a frame signed by an untrusted/attacker key fails verification',
      () async {
        final attackerSigner = await CryptoEnvelopeSigner.generate(
          keyId: 'origin-1',
        );
        final attackerAuthenticator = CryptoMediaFrameAuthenticator(
          signer: attackerSigner,
          verifier: verifier,
        );
        // Attacker mints a frame claiming to be origin-1 but signs with a key
        // that was never registered in the verifier's trusted directory under
        // that id (verifier trusts the real originSigner's public key).
        final forged = await CryptoMediaFrameAuthenticator.createOriginFrame(
          signer: attackerSigner,
          messageId: 'forged-1',
          ciphertext: utf8.encode('ciphertext'),
          createdAtMs: nowMs,
          expiresAtMs: nowMs + 60000,
          maxHops: 3,
        );
        final processor = buildProcessor(authenticator: attackerAuthenticator);

        final result = await processor.process(forged, nowMs: nowMs);

        expect(result, LinkDisposition.invalid);
        expect(delivered, isEmpty);
      },
    );

    test('forwarding: the relay re-signs the transition, preserving '
        'originKeyId and ciphertext, and the processor accepts the '
        'transition and broadcasts it', () async {
      final origin = await originFrame(messageId: 'forward-1', maxHops: 3);
      final processor = buildProcessor(
        authenticator: relayAuthenticator,
        forwardingEnabled: true,
      );

      final result = await processor.process(origin, nowMs: nowMs);

      expect(result, LinkDisposition.deliveredAndForwarded);
      expect(delivered, hasLength(1));
      expect(broadcaster.broadcasted, hasLength(1));

      final forwarded = broadcaster.broadcasted.single;
      expect(forwarded.originKeyId, origin.originKeyId);
      expect(forwarded.ciphertext, origin.ciphertext);
      expect(forwarded.messageId, origin.messageId);
      expect(forwarded.hopCount, origin.hopCount + 1);
      expect(forwarded.currentRelayKeyId, 'relay-1');
      expect(forwarded.signature, isNot(equals(origin.signature)));

      // The forwarded frame itself must independently verify (re-signed by
      // the relay, not merely copied) and be forwardable by a downstream
      // relay's processor. A separate seen-cache stands in for a distinct
      // downstream device (the shared one above already marked this
      // messageId seen from the first hop).
      final downstreamDelivered = <MediaFrame>[];
      final downstreamProcessor = LinkMessageProcessor(
        authenticator: relayAuthenticator,
        broadcaster: broadcaster,
        seenCache: LinkSeenCache(),
        onDeliver: (envelope) async {
          downstreamDelivered.add(envelope);
        },
      );
      final downstreamResult = await downstreamProcessor.process(
        forwarded,
        nowMs: nowMs + 10,
      );
      expect(downstreamResult, LinkDisposition.delivered);
      expect(downstreamDelivered, hasLength(1));
    });

    test('the hop cap is still enforced: a frame already at maxHops is '
        'delivered but not forwarded, and the authenticator is never asked '
        'to mint a transition', () async {
      final atCap = await CryptoMediaFrameAuthenticator.createOriginFrame(
        signer: originSigner,
        messageId: 'hop-cap-1',
        ciphertext: utf8.encode('ciphertext'),
        createdAtMs: nowMs,
        expiresAtMs: nowMs + 60000,
        maxHops: 2,
      );
      // Manually advance to maxHops via legitimate forwarding first.
      final hop1 = await relayAuthenticator.createForwardedEnvelope(atCap);
      final hop2 = await relayAuthenticator.createForwardedEnvelope(hop1);
      expect(hop2.hopCount, 2);
      expect(hop2.canBeForwarded, isFalse);

      final processor = buildProcessor(
        authenticator: relayAuthenticator,
        forwardingEnabled: true,
      );

      final result = await processor.process(hop2, nowMs: nowMs);

      expect(result, LinkDisposition.hopLimitReached);
      expect(delivered, hasLength(1));
      expect(broadcaster.broadcasted, isEmpty);
    });

    test('a frame whose hopCount already exceeds maxHops is rejected before '
        'signature verification is attempted', () async {
      final origin = await originFrame(messageId: 'over-cap-1', maxHops: 2);
      final malformed = MediaFrame(
        version: origin.version,
        messageId: origin.messageId,
        originKeyId: origin.originKeyId,
        currentRelayKeyId: origin.currentRelayKeyId,
        createdAtMs: origin.createdAtMs,
        expiresAtMs: origin.expiresAtMs,
        maxHops: origin.maxHops,
        hopCount: origin.maxHops + 1,
        ciphertext: origin.ciphertext,
        signature: origin.signature,
      );
      final processor = buildProcessor(
        authenticator: relayAuthenticator,
        forwardingEnabled: true,
      );

      final result = await processor.process(malformed, nowMs: nowMs);

      expect(result, LinkDisposition.rejected);
      expect(delivered, isEmpty);
    });

    test('mediaFrameSignedBytes is sensitive to every canonical field '
        '(hopCount included), so an unsigned hop-bump is detected', () async {
      final origin = await originFrame(messageId: 'field-sensitivity-1');
      final bumped = MediaFrame(
        version: origin.version,
        messageId: origin.messageId,
        originKeyId: origin.originKeyId,
        currentRelayKeyId: origin.currentRelayKeyId,
        createdAtMs: origin.createdAtMs,
        expiresAtMs: origin.expiresAtMs,
        maxHops: origin.maxHops,
        hopCount: origin.hopCount + 1,
        ciphertext: origin.ciphertext,
        signature: origin.signature,
      );

      expect(
        mediaFrameSignedBytes(bumped),
        isNot(equals(mediaFrameSignedBytes(origin))),
      );
      final ok = await originAuthenticator.verify(bumped);
      expect(ok, isFalse);
    });
  });
}
