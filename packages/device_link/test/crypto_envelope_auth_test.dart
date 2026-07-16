import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:device_link/device_link.dart';
import 'package:test/test.dart';

void main() {
  group(
    'CryptoEnvelopeSigner/CryptoEnvelopeVerifier over EnvelopeValidator',
    () {
      const nowMs = 1000000;

      late CryptoEnvelopeSigner senderSigner;
      late CryptoEnvelopeVerifier verifier;
      late EnvelopeValidator validator;

      setUp(() async {
        senderSigner = await CryptoEnvelopeSigner.generate(keyId: 'device-a');
        verifier = CryptoEnvelopeVerifier();
        verifier.trust('device-a', await senderSigner.extractPublicKey());
        validator = EnvelopeValidator(verifier: verifier);
      });

      test(
        'a real-key roundtrip signs, verifies, and passes validation',
        () async {
          final envelope = await AuthenticatedEnvelope.create(
            signer: senderSigner,
            payload: utf8.encode('hello mesh'),
            nowMs: nowMs,
          );

          final result = await validator.validate(envelope, nowMs: nowMs + 10);

          expect(result, EnvelopeValidation.valid);
        },
      );

      test('a tampered payload (signature unchanged) fails signature '
          'verification', () async {
        final envelope = await AuthenticatedEnvelope.create(
          signer: senderSigner,
          payload: utf8.encode('original payload'),
          nowMs: nowMs,
        );
        final tampered = AuthenticatedEnvelope(
          nonce: envelope.nonce,
          senderKeyId: envelope.senderKeyId,
          sentAtMs: envelope.sentAtMs,
          payload: utf8.encode('tampered payload!'),
          signature: envelope.signature,
        );

        final result = await validator.validate(tampered, nowMs: nowMs + 10);

        expect(result, EnvelopeValidation.badSignature);
      });

      test('a tampered nonce (signature unchanged) fails signature '
          'verification', () async {
        final envelope = await AuthenticatedEnvelope.create(
          signer: senderSigner,
          payload: utf8.encode('payload'),
          nowMs: nowMs,
        );
        final tampered = AuthenticatedEnvelope(
          nonce: '${envelope.nonce}-x',
          senderKeyId: envelope.senderKeyId,
          sentAtMs: envelope.sentAtMs,
          payload: envelope.payload,
          signature: envelope.signature,
        );

        final result = await validator.validate(tampered, nowMs: nowMs + 10);

        expect(result, EnvelopeValidation.badSignature);
      });

      test('a replayed envelope (same nonce, valid signature) is rejected on '
          'the second delivery', () async {
        final envelope = await AuthenticatedEnvelope.create(
          signer: senderSigner,
          payload: utf8.encode('payload'),
          nowMs: nowMs,
        );

        final first = await validator.validate(envelope, nowMs: nowMs + 10);
        final second = await validator.validate(envelope, nowMs: nowMs + 20);

        expect(first, EnvelopeValidation.valid);
        expect(second, EnvelopeValidation.replayed);
      });

      test('a signature produced by a different (stolen/attacker) key fails '
          'verification and does not consume the nonce', () async {
        final attackerSigner = await CryptoEnvelopeSigner.generate(
          keyId: 'device-a',
        );
        // The attacker signs as if it were device-a, but device-a's trusted
        // public key on the verifier's directory is the real one, so the
        // forged signature must not verify.
        final unsigned = AuthenticatedEnvelope(
          nonce: generateEnvelopeNonce(),
          senderKeyId: 'device-a',
          sentAtMs: nowMs,
          payload: utf8.encode('payload'),
          signature: const [],
        );
        final forgedSignature = await attackerSigner.sign(
          unsigned.signedBytes(),
        );
        final forged = AuthenticatedEnvelope(
          nonce: unsigned.nonce,
          senderKeyId: unsigned.senderKeyId,
          sentAtMs: unsigned.sentAtMs,
          payload: unsigned.payload,
          signature: forgedSignature,
        );

        final result = await validator.validate(forged, nowMs: nowMs + 10);
        expect(result, EnvelopeValidation.badSignature);

        // Nonce must not have been consumed: a legitimately-signed envelope
        // reusing the same nonce must still be able to validate.
        final legitimateSignature = await senderSigner.sign(
          unsigned.signedBytes(),
        );
        final legitimate = AuthenticatedEnvelope(
          nonce: unsigned.nonce,
          senderKeyId: unsigned.senderKeyId,
          sentAtMs: unsigned.sentAtMs,
          payload: unsigned.payload,
          signature: legitimateSignature,
        );
        final secondResult = await validator.validate(
          legitimate,
          nowMs: nowMs + 11,
        );
        expect(secondResult, EnvelopeValidation.valid);
      });

      test('an unknown sender key id is rejected without throwing', () async {
        final unknownSigner = await CryptoEnvelopeSigner.generate(
          keyId: 'device-unknown',
        );
        final envelope = await AuthenticatedEnvelope.create(
          signer: unknownSigner,
          payload: utf8.encode('payload'),
          nowMs: nowMs,
        );

        final result = await validator.validate(envelope, nowMs: nowMs + 10);

        expect(result, EnvelopeValidation.badSignature);
      });

      test(
        'CryptoEnvelopeVerifier.revoke removes a previously trusted key',
        () async {
          final envelope = await AuthenticatedEnvelope.create(
            signer: senderSigner,
            payload: utf8.encode('payload'),
            nowMs: nowMs,
          );
          verifier.revoke('device-a');

          final result = await validator.validate(envelope, nowMs: nowMs + 10);

          expect(result, EnvelopeValidation.badSignature);
        },
      );

      test(
        'CryptoEnvelopeSigner.fromKeyPair wraps a pre-generated key pair and '
        'signs/verifies identically to .generate',
        () async {
          final keyPair = await Ed25519().newKeyPair();
          final rehydratedSigner = CryptoEnvelopeSigner.fromKeyPair(
            keyId: 'device-b',
            keyPair: keyPair,
          );
          final rehydratedVerifier = CryptoEnvelopeVerifier();
          rehydratedVerifier.trust(
            'device-b',
            await rehydratedSigner.extractPublicKey(),
          );
          final rehydratedValidator = EnvelopeValidator(
            verifier: rehydratedVerifier,
          );

          final envelope = await AuthenticatedEnvelope.create(
            signer: rehydratedSigner,
            payload: utf8.encode('payload'),
            nowMs: nowMs,
          );
          final result = await rehydratedValidator.validate(
            envelope,
            nowMs: nowMs + 10,
          );

          expect(result, EnvelopeValidation.valid);
        },
      );
    },
  );
}
