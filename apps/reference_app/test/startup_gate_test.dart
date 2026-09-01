import 'package:flutter_test/flutter_test.dart';
import 'package:reference_app/src/startup_manifest.dart';
import 'package:signed_config/signed_config.dart';

/// Cross-cutting verdict 2 — the bootstrap retrieval rule.
///
/// The admission rule that governs a session reads its thresholds and its
/// candidate settings from a document the app must retrieve. Running the
/// retrieval under that same rule is a self-reference: a device in poor
/// conditions would be refused before it could obtain the document that
/// defines the rule that refused it, with no route forward.
///
/// The rule adopted instead: retrieval never runs under the gate it defines.
/// It runs under its own named bounds, compiled in — which is legitimate here
/// precisely because those bounds promise no quality property, they only cap
/// time and effort — and until a document is held the app admits no caller.
/// Nothing is silently withdrawn during startup because nothing has been
/// promised yet.
void main() {
  EndpointManifest manifest() => EndpointManifest(
    schemaVersion: manifestSchemaVersion,
    revision: 1,
    signingKeyId: 'key-1',
    issuedAt: DateTime.utc(2026, 1, 1),
    expiresAt: DateTime.utc(2027, 1, 1),
    signalingEndpoints: [Uri.parse('wss://signal.example.com/v1')],
    iceServers: [
      IceServerEntry(
        urls: [Uri.parse('turns:relay.example:443')],
        username: 'u',
        credential: 'c',
      ),
    ],
    configServiceUris: [Uri.parse('https://config.example.com/manifest')],
    relayRegions: const ['eu-central'],
    featureFlags: const {},
  );

  group('StartupManifestGate', () {
    test('before retrieval nothing is held and no caller is admitted', () {
      final gate = StartupManifestGate();
      expect(gate.phase, StartupPhase.notStarted);
      expect(gate.holdsUsableManifest, isFalse);
      expect(() => gate.requireManifest(), throwsA(isA<StartupNotReady>()));
    });

    test(
      'a successful retrieval admits callers and names its source',
      () async {
        final gate = StartupManifestGate();
        final held = await gate.retrieve(
          () async => StartupManifest(manifest(), ManifestSource.signedConfig),
        );
        expect(held.source, ManifestSource.signedConfig);
        expect(gate.holdsUsableManifest, isTrue);
        expect(gate.phase, StartupPhase.ready);
        expect(gate.requireManifest().manifest, isNotNull);
      },
    );

    test('the attempt cap is a loud failure naming the cap, not a silent fall '
        'to another rung', () async {
      final policy = const StartupRetrievalPolicy(maxAttempts: 3);
      final gate = StartupManifestGate(policy: policy);
      var attempts = 0;
      await expectLater(
        gate.retrieve(() async {
          attempts++;
          return const StartupManifest(null, ManifestSource.none);
        }),
        throwsA(
          isA<StartupBudgetExceeded>().having(
            (e) => e.toString(),
            'toString',
            contains('maxAttempts'),
          ),
        ),
      );
      expect(attempts, 3, reason: 'bounded, never an unbounded retry loop');
      expect(gate.holdsUsableManifest, isFalse);
    });

    test('after the budget is spent, refusals name the same cap', () async {
      final gate = StartupManifestGate(
        policy: const StartupRetrievalPolicy(maxAttempts: 1),
      );
      try {
        await gate.retrieve(
          () async => const StartupManifest(null, ManifestSource.none),
        );
      } on StartupBudgetExceeded {
        // expected
      }
      expect(gate.phase, StartupPhase.budgetExhausted);
      expect(
        () => gate.requireManifest(),
        throwsA(
          isA<StartupNotReady>().having(
            (e) => e.toString(),
            'toString',
            contains('maxAttempts'),
          ),
        ),
        reason:
            'a device with no document must be told why, not left to '
            'discover it as a call that never connects',
      );
    });

    test('the total deadline caps a slow attempt', () async {
      final gate = StartupManifestGate(
        policy: const StartupRetrievalPolicy(
          attemptDeadline: Duration(milliseconds: 20),
          totalDeadline: Duration(milliseconds: 60),
          maxAttempts: 100,
        ),
      );
      await expectLater(
        gate.retrieve(() async {
          await Future<void>.delayed(const Duration(seconds: 5));
          return StartupManifest(manifest(), ManifestSource.signedConfig);
        }),
        throwsA(isA<StartupBudgetExceeded>()),
        reason:
            'a slow source must not turn a refusal into an unbounded '
            'startup delay',
      );
      expect(gate.holdsUsableManifest, isFalse);
    });

    test('a later attempt can succeed after earlier ones failed', () async {
      final gate = StartupManifestGate(
        policy: const StartupRetrievalPolicy(maxAttempts: 4),
      );
      var attempt = 0;
      final held = await gate.retrieve(() async {
        attempt++;
        if (attempt < 3)
          return const StartupManifest(null, ManifestSource.none);
        return StartupManifest(manifest(), ManifestSource.outOfBand);
      });
      expect(attempt, 3);
      expect(held.source, ManifestSource.outOfBand);
      expect(gate.holdsUsableManifest, isTrue);
    });

    test('the bootstrap bounds are compiled in, and that is deliberate: they '
        'cap time and effort, not a quality property', () {
      const defaults = StartupRetrievalPolicy.defaults;
      expect(defaults.attemptDeadline, greaterThan(Duration.zero));
      expect(defaults.totalDeadline, greaterThan(defaults.attemptDeadline));
      expect(defaults.maxAttempts, greaterThan(0));
    });
  });
}
