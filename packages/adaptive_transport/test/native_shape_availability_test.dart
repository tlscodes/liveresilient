/// Gates 4d and 4g — the one-member status value, and where an available
/// answer is allowed to come from.
///
/// 4d asks for a status type with exactly one member today, and an
/// exhaustiveness proof that a second member is not expressible until the
/// native binding actually works. 4g asks that the ordinary path report absent,
/// and that an available report could only ever come from a run-time probe —
/// never from a compile-time flag.
///
/// TWO KINDS OF EVIDENCE HERE, and the difference matters.
///
/// The exhaustiveness half is proven by COMPILATION: the switch in
/// `_describe` below has no default branch and no wildcard, so the day someone
/// adds a second member this file stops compiling. That is the gate working;
/// the fix is to revisit every consumer, which is the whole point.
///
/// The shape half is proven by reading the library source, because the claim IS
/// about the source's shape — one member, a sealed base, a private constructor,
/// no environment flag. A source predicate that has only ever seen the source it
/// was written against proves nothing, so each predicate is also run over a
/// SYNTHETIC counterexample and must report the violation. That is the red half
/// of red-green, permanent and in-file, rather than a mutation someone once did
/// by hand and undid.
import 'dart:io';

import 'package:adaptive_transport/adaptive_transport.dart';
import 'package:test/test.dart';

/// Exhaustive over the sealed type, deliberately with no default and no `_`.
/// Adding a member breaks this line at compile time.
String _describe(NativeShapeAvailability status) => switch (status) {
  NativeShapeAbsent(:final cause) => 'absent:${cause.name}',
};

String _librarySource() {
  for (final candidate in [
    'lib/src/probe_defense/native_shape_availability.dart',
    'packages/adaptive_transport/lib/src/probe_defense/'
        'native_shape_availability.dart',
  ]) {
    final file = File(candidate);
    if (file.existsSync()) return file.readAsStringSync();
  }
  throw StateError(
    'native_shape_availability.dart not found from '
    '${Directory.current.path}',
  );
}

/// Counts `final class X extends NativeShapeAvailability` declarations.
///
/// Positional rather than name-based: it does not care what the member is
/// called, only how many there are, so renaming cannot slip a second one past.
int _memberCount(String source) => RegExp(
  r'(?:final|base|sealed)\s+class\s+\w+\s+extends\s+NativeShapeAvailability',
).allMatches(source).length;

bool _baseIsSealed(String source) =>
    RegExp(r'sealed\s+class\s+NativeShapeAvailability\b').hasMatch(source);

bool _constructorIsPrivate(String source) =>
    RegExp(r'const\s+NativeShapeAvailability\._\(\)').hasMatch(source);

/// Strips doc comments, line comments and block comments.
///
/// Found by this file's first red run: the library's own doc comment names
/// `bool.fromEnvironment` in the sentence forbidding it, and the flag predicate
/// matched the prose. A gate that fires on the documentation of a rule is not
/// measuring the rule — the unit is code, so the comments come out first.
String _codeOnly(String source) => source
    .replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '')
    .split('\n')
    .where((line) => !line.trimLeft().startsWith('//'))
    .join('\n');

/// True when the CODE reaches for a compile-time switch. `fromEnvironment` in
/// any form is the one this gate is about; a bare `const bool` is fine, so the
/// predicate names the actual mechanism rather than a nearby smell.
bool _readsBuildFlag(String source) =>
    RegExp(r'\bfromEnvironment\b').hasMatch(_codeOnly(source));

void main() {
  final source = _librarySource();

  group('4d the status type has exactly one member', () {
    test('4d one member in the library, and a second one would be seen', () {
      expect(
        _memberCount(source),
        1,
        reason: 'one member today, meaning absent',
      );

      // The predicate proves it can count to two, on a source it has never
      // seen. Without this the assertion above could be a regex that matches
      // nothing and passes forever.
      const twoMembers = '''
sealed class NativeShapeAvailability { const NativeShapeAvailability._(); }
final class NativeShapeAbsent extends NativeShapeAvailability {}
final class NativeShapePresent extends NativeShapeAvailability {}
''';
      expect(_memberCount(twoMembers), 2);
    });

    test('4d the base is sealed and its constructor is private', () {
      // Sealed alone bounds the subtypes to this library; the private
      // constructor is what stops a subclass being declared beside it in the
      // same file by accident. Both, or the one-member claim is a convention.
      expect(_baseIsSealed(source), isTrue);
      expect(_constructorIsPrivate(source), isTrue);

      expect(
        _baseIsSealed('abstract class NativeShapeAvailability {}'),
        isFalse,
      );
      expect(
        _constructorIsPrivate('const NativeShapeAvailability();'),
        isFalse,
      );
    });

    test('4d the exhaustive switch covers the type with no default', () {
      // Compilation is the real assertion — `_describe` has no default branch.
      // This case exists so the compiled proof is also executed and named.
      expect(
        _describe(nativeShapeAvailabilityForThisBuild),
        'absent:noModuleLinked',
      );
      expect(
        _codeOnly(source).contains('default:'),
        isFalse,
        reason:
            'a default branch would defeat the exhaustiveness that IS '
            'the mechanism',
      );
    });
  });

  group('4g where an available answer may come from', () {
    test('4g every probe outcome resolves to absent today', () {
      for (final outcome in NativeShapeProbeOutcome.values) {
        expect(
          resolveNativeShapeAvailability(outcome),
          isA<NativeShapeAbsent>(),
          reason: '$outcome must not be able to produce an available status',
        );
      }
      // Every outcome enumerated, so a new one cannot be added without this
      // loop covering it.
      expect(NativeShapeProbeOutcome.values.length, 3);
    });

    test('4g a probe that reports success is still absent, and says why', () {
      // The load-bearing case. A caller CAN hand in a successful probe — a fake
      // one, a future real one — and the answer is still absent, with a cause
      // that names the reason rather than implying a failure that did not
      // happen. This is what makes the gate structural instead of trusting the
      // caller to be honest.
      final resolved = resolveNativeShapeAvailability(
        NativeShapeProbeOutcome.moduleAnsweredYes,
      );
      expect(
        resolved,
        isA<NativeShapeAbsent>().having(
          (a) => a.cause,
          'cause',
          NativeShapeAbsentCause.probeSucceededButPresentStateNotRepresentable,
        ),
      );
    });

    test('4g the ordinary build reports absent for the right reason', () {
      expect(
        nativeShapeAvailabilityForThisBuild,
        isA<NativeShapeAbsent>().having(
          (a) => a.cause,
          'cause',
          NativeShapeAbsentCause.noModuleLinked,
        ),
      );
      expect(
        resolveNativeShapeAvailability(NativeShapeProbeOutcome.noModuleToProbe),
        nativeShapeAvailabilityForThisBuild,
        reason:
            'the constant and the resolver must agree, or one of them is a '
            'second source of truth',
      );
    });

    test('4g no compile-time flag feeds the resolver', () {
      expect(_readsBuildFlag(source), isFalse);

      // And the predicate can see one when it is there.
      expect(
        _readsBuildFlag('const linked = bool.fromEnvironment("HAS_MODULE");'),
        isTrue,
      );
    });

    test('4g the cause enum has no member meaning available', () {
      // A field can smuggle back what the sealed type forbids: one enum member
      // named like success and the claim is representable again. Positional
      // check — every member must be a reason for absence.
      for (final cause in NativeShapeAbsentCause.values) {
        expect(
          cause.name.toLowerCase(),
          isNot(
            anyOf(
              contains('present\$'),
              equals('available'),
              equals('ready'),
              equals('enabled'),
              equals('active'),
            ),
          ),
          reason:
              '${cause.name} reads like availability inside an '
              'absence-cause enum',
        );
      }
    });
  });
}
