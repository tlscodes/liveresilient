import 'dart:typed_data';

import 'package:signed_config/signed_config.dart';
import 'package:test/test.dart';

import 'support/fakes.dart';

/// Ticket 5 acceptance gate 5f — a lower revision is refused even when it was
/// signed more recently.
///
/// THE ATTACK THIS IS ABOUT. Freshness and version are different orderings, and
/// an attacker who can re-sign controls the first one. Re-issuing an OLD
/// configuration with a NEW issuedAt makes it look like the latest word from the
/// operator while rolling the device back to whatever that configuration
/// allowed. So recency must never outrank the revision counter.
///
/// WHY THIS FILE EXISTS SEPARATELY. The rollback branch was already in the
/// verifier and no test asked it this question — the classification in
/// docs/GATE_CLASSIFICATION.md recorded 5f as a missing test rather than a
/// missing feature. A branch nobody interrogates is a branch that can be
/// reordered or dropped by a later refactor with every suite still green, which
/// is precisely what happened to the time checks before ticket 5.
///
/// ORDERING IS PART OF THE CLAIM, AND IT IS PINNED HERE ON PURPOSE. In the
/// verifier the time-window checks run BEFORE the rollback check, so a stale
/// document that is ALSO outside its window is reported as expired or
/// not-yet-valid rather than as a rollback. Both are refusals, so the gate
/// holds either way — but a caller that branches on the reason would see a
/// different answer, so the tests below assert the reason for the in-window
/// case and state the out-of-window behaviour explicitly instead of leaving a
/// future reader to discover it.
void main() {
  group('gate 5f — revision outranks recency', () {
    late FakeEd25519Verifier crypto;
    late Uint8List key1;
    late ManifestVerifier verifier;

    // The device has already accepted revision 42.
    const accepted = 42;
    final acceptedIssuedAt = DateTime.utc(2026, 1, 10);

    setUp(() {
      crypto = FakeEd25519Verifier();
      key1 = keyBytes(1);
      verifier = ManifestVerifier(
        pinnedKeys: [PinnedManifestKey(keyId: 'key-1', publicKey: key1)],
        crypto: crypto,
      );
    });

    SignedManifestDocument doc({
      required int revision,
      required DateTime issuedAt,
      Duration validFor = const Duration(days: 7),
    }) => signManifest(
      buildManifest(
        revision: revision,
        issuedAt: issuedAt,
        expiresAt: issuedAt.add(validFor),
      ),
      key1,
    );

    test('5f  a lower revision signed one day later is refused as a rollback',
        () async {
      final resigned = doc(
        revision: accepted - 2, // the old configuration
        issuedAt: acceptedIssuedAt.add(const Duration(days: 1)), // newer stamp
      );

      final result = await verifier.verify(
        resigned,
        lastAcceptedRevision: accepted,
        // Inside the re-signed document's own window, so the time checks pass
        // and the decision is made on the revision alone.
        now: acceptedIssuedAt.add(const Duration(days: 2)),
      );

      expect(result, isA<ManifestRejected>());
      expect(
        (result as ManifestRejected).reason,
        ManifestRejection.rollback,
        reason: 'the document is authentic and in-window; the ONLY thing wrong '
            'with it is that it moves the device backwards',
      );
    });

    test('5f  a much newer signature does not buy a rollback either', () async {
      // The recency advantage is unbounded — a year of it changes nothing,
      // because the two orderings are independent.
      final resigned = doc(
        revision: 1,
        issuedAt: acceptedIssuedAt.add(const Duration(days: 365)),
      );

      final result = await verifier.verify(
        resigned,
        lastAcceptedRevision: accepted,
        now: acceptedIssuedAt.add(const Duration(days: 366)),
      );

      expect((result as ManifestRejected).reason, ManifestRejection.rollback);
    });

    test('5f  the same revision is accepted, so the rule is not "strictly '
        'newer"', () async {
      // The boundary matters: refusing an equal revision would make a
      // re-fetch of the current configuration fail, and a device that cannot
      // re-read its own configuration is a different outage.
      final same = doc(
        revision: accepted,
        issuedAt: acceptedIssuedAt.add(const Duration(days: 1)),
      );

      final result = await verifier.verify(
        same,
        lastAcceptedRevision: accepted,
        now: acceptedIssuedAt.add(const Duration(days: 2)),
      );

      expect(result, isA<ManifestAccepted>());
    });

    test('5f  a higher revision with an older signature is still accepted',
        () async {
      // The mirror of the gate: recency does not outrank revision in EITHER
      // direction. A document that is authentic, in-window and ahead of the
      // device is accepted even though it was stamped before the one the
      // device holds — otherwise an attacker could block updates by
      // replaying a recent stamp.
      final ahead = doc(
        revision: accepted + 1,
        issuedAt: acceptedIssuedAt.subtract(const Duration(days: 1)),
      );

      final result = await verifier.verify(
        ahead,
        lastAcceptedRevision: accepted,
        now: acceptedIssuedAt,
      );

      expect(result, isA<ManifestAccepted>());
    });

    test('5f  out of window, the refusal is reported as a time failure — the '
        'documented consequence of check order', () async {
      // Not a defect, and not left implicit: the caller still gets a refusal,
      // but the REASON is the time check because it runs first. Asserting it
      // here means a future reorder shows up as a failing test rather than as
      // a silently different reason reaching callers.
      final staleAndExpired = doc(
        revision: 1,
        issuedAt: acceptedIssuedAt,
        validFor: const Duration(days: 1),
      );

      final result = await verifier.verify(
        staleAndExpired,
        lastAcceptedRevision: accepted,
        now: acceptedIssuedAt.add(const Duration(days: 30)),
      );

      expect(
        (result as ManifestRejected).reason,
        ManifestRejection.expired,
        reason: 'time checks precede the rollback check; both refuse, and this '
            'test exists so the difference is a decision rather than a '
            'surprise',
      );
    });
  });
}
