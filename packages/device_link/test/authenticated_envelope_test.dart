import 'dart:convert';

import 'package:device_link/device_link.dart';
import 'package:test/test.dart';

import 'support/fakes.dart';

Map<String, Object?> _validEnvelopeJson({
  int version = 1,
  String nonce = 'n',
}) => {
  'v': version,
  'nonce': nonce,
  'senderKeyId': 'device-a',
  'sentAtMs': 1700000000000,
  'payload': base64Encode(utf8.encode('hi')),
  'signature': base64Encode([1, 2, 3]),
};

void main() {
  group('AuthenticatedEnvelope + EnvelopeValidator', () {
    late FakeSigner signer;
    late FakeVerifier verifier;
    late EnvelopeValidator validator;
    const nowMs = 1700000000000;

    setUp(() {
      signer = FakeSigner('device-a');
      verifier = FakeVerifier({'device-a'});
      validator = EnvelopeValidator(verifier: verifier);
    });

    test('a validly signed, fresh envelope round-trips as valid', () async {
      final envelope = await AuthenticatedEnvelope.create(
        signer: signer,
        payload: utf8.encode('hello peer'),
        nowMs: nowMs,
      );

      final result = await validator.validate(envelope, nowMs: nowMs + 5000);

      expect(result, EnvelopeValidation.valid);
    });

    test('an envelope delivered outside the freshness window is rejected as '
        'stale', () async {
      final envelope = await AuthenticatedEnvelope.create(
        signer: signer,
        payload: utf8.encode('late'),
        nowMs: nowMs,
      );

      final result = await validator.validate(
        envelope,
        nowMs: nowMs + const Duration(minutes: 2).inMilliseconds + 1,
      );

      expect(result, EnvelopeValidation.stale);
    });

    test(
      'a failing signature is rejected without consuming the nonce cache, '
      'so the same nonce with a valid signature still succeeds afterwards',
      () async {
        final good = await AuthenticatedEnvelope.create(
          signer: signer,
          payload: utf8.encode('payload'),
          nowMs: nowMs,
        );
        // Same nonce/sender/timestamp/payload as `good`, but a signature
        // that cannot possibly verify.
        final tampered = AuthenticatedEnvelope(
          nonce: good.nonce,
          senderKeyId: good.senderKeyId,
          sentAtMs: good.sentAtMs,
          payload: good.payload,
          signature: const [0, 1, 2, 3],
        );

        final badResult = await validator.validate(tampered, nowMs: nowMs);
        expect(badResult, EnvelopeValidation.badSignature);

        final goodResult = await validator.validate(good, nowMs: nowMs);
        expect(
          goodResult,
          EnvelopeValidation.valid,
          reason:
              'the failed-signature attempt must not have reserved the '
              'nonce cache slot for this nonce',
        );
      },
    );

    test('a replayed nonce is rejected on the second delivery', () async {
      final envelope = await AuthenticatedEnvelope.create(
        signer: signer,
        payload: utf8.encode('once only'),
        nowMs: nowMs,
      );

      final first = await validator.validate(envelope, nowMs: nowMs);
      final second = await validator.validate(envelope, nowMs: nowMs + 10);

      expect(first, EnvelopeValidation.valid);
      expect(second, EnvelopeValidation.replayed);
    });

    test(
      'a payload over the local link limit is rejected at create time',
      () async {
        final oversized = List<int>.filled(maxLocalPayloadBytes + 1, 7);

        await expectLater(
          AuthenticatedEnvelope.create(
            signer: signer,
            payload: oversized,
            nowMs: nowMs,
          ),
          throwsFormatException,
        );
      },
    );

    test('fromBytes round-trips a valid envelope through toBytes', () async {
      final original = await AuthenticatedEnvelope.create(
        signer: signer,
        payload: utf8.encode('round trip'),
        nowMs: nowMs,
      );

      final decoded = AuthenticatedEnvelope.fromBytes(original.toBytes());

      expect(decoded.nonce, original.nonce);
      expect(decoded.senderKeyId, original.senderKeyId);
      expect(decoded.sentAtMs, original.sentAtMs);
      expect(decoded.payload, original.payload);
      expect(decoded.signature, original.signature);
    });

    test('fromBytes rejects a JSON payload that is not an object', () {
      expect(
        () => AuthenticatedEnvelope.fromBytes(utf8.encode(jsonEncode([1, 2]))),
        throwsFormatException,
      );
    });

    test('fromBytes rejects an object missing or mistyping fields', () {
      final incomplete = jsonEncode({'v': 1, 'nonce': 'only-one-field'});

      expect(
        () => AuthenticatedEnvelope.fromBytes(utf8.encode(incomplete)),
        throwsFormatException,
      );
    });

    test('fromBytes rethrows the domain FormatException for a structurally '
        'valid but unsupported envelope version', () {
      final badVersion = jsonEncode(_validEnvelopeJson(version: 2));

      expect(
        () => AuthenticatedEnvelope.fromBytes(utf8.encode(badVersion)),
        throwsFormatException,
      );
    });

    test('EnvelopeValidator rejects a non-positive maxTrackedNonces at '
        'construction', () {
      expect(
        () => EnvelopeValidator(verifier: verifier, maxTrackedNonces: 0),
        throwsA(isA<RangeError>()),
      );
    });

    test('once the tracked-nonce cap is exceeded, the oldest nonce is evicted '
        'and can be validated again', () async {
      final capped = EnvelopeValidator(verifier: verifier, maxTrackedNonces: 1);
      final first = await AuthenticatedEnvelope.create(
        signer: signer,
        payload: utf8.encode('first'),
        nowMs: nowMs,
      );
      final second = await AuthenticatedEnvelope.create(
        signer: signer,
        payload: utf8.encode('second'),
        nowMs: nowMs,
      );

      expect(
        await capped.validate(first, nowMs: nowMs),
        EnvelopeValidation.valid,
      );
      expect(
        await capped.validate(second, nowMs: nowMs),
        EnvelopeValidation.valid,
      );

      // The cap is 1, so admitting `second` evicted `first`'s nonce: it
      // is no longer tracked as replayed.
      expect(
        await capped.validate(first, nowMs: nowMs),
        EnvelopeValidation.valid,
      );
    });
  });
}
