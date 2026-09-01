import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:signed_config/signed_config.dart'
    show IceProfile, iceProfileFor;

/// Ticket 3 gate 3c — the rig's ICE transport policy is decided by the SAME
/// function production uses.
///
/// WHAT WENT WRONG ORIGINALLY. The rig read an environment flag and picked the
/// policy string itself. That made every shaped-network row prove something
/// about a path production never takes: the profile rule was bypassed, so a
/// defect inside it could not be caught by the one harness built to catch
/// exactly that class of defect. A rig that exercises its own private branch
/// reports on the rig.
///
/// The fix was made in wave 4 and is unproven until now: the flag enters where
/// a real deployment's flag enters — the manifest's feature flags — and the
/// policy string is derived from whatever profile the production mapper
/// returns.
///
/// WHY PART OF THIS TEST READS SOURCE. The rig's flag is a compile-time
/// constant (`bool.fromEnvironment`), so a unit test cannot flip it and observe
/// both branches at run time. Behaviour alone therefore cannot distinguish
/// "derived from the mapper" from "a hardcoded string that happens to match the
/// mapper for the current flag". The source assertion closes precisely that
/// gap, in the same style as the 6b wiring test next to this file: it fails if
/// the shortcut is ever reintroduced, which is the regression that matters.
void main() {
  final root = Directory.current.path;
  final support = File('$root/integration_test/support/e2e_support.dart');

  group('gate 3c — the rig goes through the production decision', () {
    test('3c  the rig derives its policy from iceProfileFor, not from the flag', () {
      expect(
        support.existsSync(),
        isTrue,
        reason:
            'the rig support file is the subject of this gate: '
            '${support.path}',
      );
      final source = support.readAsStringSync();

      // The body of e2eIceTransportPolicy, isolated so the assertions below
      // cannot be satisfied by some unrelated part of the file.
      final start = source.indexOf('String e2eIceTransportPolicy()');
      expect(
        start,
        greaterThan(-1),
        reason: 'the rig must still expose the derivation it is tested for',
      );
      final end = source.indexOf('\n}', start);
      final body = source.substring(start, end < 0 ? source.length : end);

      expect(
        body,
        contains('iceProfileFor('),
        reason:
            'the policy must come from the production rule; calling it is '
            'the only way the rig can inherit a fix or a defect in it',
      );
      expect(
        body,
        contains('IceProfile.strictRelay'),
        reason:
            'the string must be derived from the returned profile, not '
            'chosen alongside it',
      );
      // THE SHORTCUT, RULED OUT BY POSITION RATHER THAN BY SHAPE.
      //
      // Naming the flag is fine — it is the input the rule receives. What must
      // not happen is the flag reaching the RESULT. Enumerating the forms that
      // shortcut could take (`flag ? … : …`, `if (flag) return …`, a switch, a
      // helper) is a losing game, so the assertions are positional instead and
      // hold for any shape:
      //
      //   · every mention of the flag sits in the feature-flag map
      //   · every policy string literal sits on the line that reads the profile
      //
      // A flag that decides the string violates one or both, whatever syntax it
      // is written in.
      final lines = body.split('\n');
      final flagOutsideFlags = lines
          .where((l) => l.contains('e2eForceRelay'))
          .where((l) => !l.contains('strict_relay'))
          .toList();
      expect(
        flagOutsideFlags,
        isEmpty,
        reason:
            'the flag must only enter as a manifest feature flag; here it '
            'reaches the result directly: $flagOutsideFlags',
      );
      final literalAwayFromProfile = lines
          .where((l) => l.contains("'relay'") || l.contains("'all'"))
          .where((l) => !l.contains('IceProfile.'))
          .toList();
      expect(
        literalAwayFromProfile,
        isEmpty,
        reason:
            'a policy string must be produced from the returned profile '
            'and nowhere else: $literalAwayFromProfile',
      );
      expect(
        body,
        contains("'strict_relay'"),
        reason:
            'the flag must enter as a manifest feature flag, which is '
            'where a real deployment supplies it',
      );
    });

    test('3c  the production rule maps both flag states, so the rig inherits '
        'both', () {
      // The rig hands the flag through as a feature flag. Exercising the rule
      // directly with both values proves the derivation the rig relies on
      // exists and is not degenerate — the compiled flag only selects which of
      // these two rows the rig takes on a given run.
      expect(
        iceProfileFor(
          iceFailureCount: 0,
          featureFlags: const <String, bool>{'strict_relay': true},
        ),
        IceProfile.strictRelay,
      );
      expect(
        iceProfileFor(
          iceFailureCount: 0,
          featureFlags: const <String, bool>{'strict_relay': false},
        ),
        IceProfile.normal,
      );
    });

    test('3c  the same function also owns the two-failure rule, so the rig '
        'cannot diverge from production on it either', () {
      // If the rig had kept its own branch, this rule would apply in
      // production and not in the harness — the two would disagree exactly
      // where a shaped-network row is most likely to hit it.
      expect(
        iceProfileFor(iceFailureCount: 1, featureFlags: const <String, bool>{}),
        IceProfile.normal,
        reason: 'one failure is a transient',
      );
      expect(
        iceProfileFor(iceFailureCount: 2, featureFlags: const <String, bool>{}),
        IceProfile.strictRelay,
        reason:
            'two failures on the same call is the evidence the rule waits '
            'for',
      );
    });

    test('3c  production reaches the policy through the same mapper', () {
      // The app side of the same claim: the composition root must not compute
      // a transport policy string of its own. Both sides deriving from one
      // function is what makes the rig meaningful.
      final main = File('$root/lib/main.dart').readAsStringSync();
      expect(
        main,
        contains('iceProfileFor('),
        reason: 'the composition root uses the production rule',
      );
      final handRolled = RegExp(
        "iceTransportPolicy:\\s*'(relay|all)'",
      ).hasMatch(main);
      expect(
        handRolled,
        isFalse,
        reason:
            'a literal policy string in the app would fork the decision '
            'the rig is asserting it shares',
      );
    });
  });
}
