/// Gates 4e and 4f — the app's surface for a capability that is not built.
///
/// 4e is a RENDERED-OUTPUT test: with the ordinary path active, any surface that
/// says anything about this capability must display the absent state explicitly.
/// 4f is an ARCHITECTURE test: presentation modules have no direct access to the
/// wording or the state of an available capability; the only route is the status
/// value from the transport package.
///
/// WHY THIS IS NOT A STRING SEARCH FOR A CLAIM. The plan rejected that gate and
/// gave five reasons it cannot work: strings assembled at run time, a translation
/// catalogue, text arriving from a server-side document, a non-textual claim (a
/// lock icon, a colour, a tick), and erosion — a reworded sentence quietly
/// sidesteps the pattern. The replacement inverts the direction: the claim is not
/// authored at the surface at all, it is DERIVED from the status value. Then a
/// false claim is not something to search for, it is something you cannot
/// construct. These two tests measure that inversion, so:
///
///   * 4e asserts the panel renders EXACTLY what the value's own translator
///     returns. It does not hardcode the sentence — a test that spelled out the
///     wording would become the definition of the claim, which is the reference
///     shift the plan warned about.
///   * separately, the translator's output is checked for content, so deriving
///     from the value cannot mean deriving a lie.
///   * 4f asserts the wording lives in exactly one file and that no surface
///     builds the status itself.
///
/// Every predicate is also run against a counterexample it has never seen, so a
/// finder or a regex that matches nothing cannot pass unnoticed.
library;

import 'dart:io';

import 'package:adaptive_transport/adaptive_transport.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reference_app/src/ui/diagnostics_panel.dart';
import 'package:reference_app/src/ui/network_truth.dart';
import 'package:reference_app/src/ui/tokens.dart' show buildAppThemeData;

/// The one file allowed to contain prose about this capability.
const String _wordingOwner = 'lib/src/ui/network_truth.dart';

/// Comments out, because the unit of both predicates below is CODE. Found by
/// this file's first red run twice over: the panel's doc comment describes the
/// row it renders, and a doc comment cannot appear on a screen. A gate that
/// fires on a file's documentation is measuring the wrong thing — the same
/// mistake the transport-side test made an hour earlier, which is why it is
/// written down here as well.
String _codeOnly(String source) => source
    .replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '')
    .split('\n')
    .where((line) => !line.trimLeft().startsWith('//'))
    .join('\n');

/// Prose mentions have a space; identifiers like `nativeShapeAvailabilityText`
/// and `_NativeShapeAvailabilityRow` do not. That distinction is the whole point
/// of this predicate: referring to the value is required, authoring words about
/// it is what belongs in one place.
bool _hasProse(String source) =>
    RegExp(r'native\s+shape', caseSensitive: false).hasMatch(_codeOnly(source));

/// Constructing the status inline is the smuggling route this forbids: the value
/// must come from the package's own constant or resolver, so there is one place
/// that decides what this build reports.
///
/// A DESTRUCTURING PATTERN IS NOT A CONSTRUCTION, and telling them apart is the
/// difference between this gate working and this gate crying wolf. `switch
/// (status) { NativeShapeAbsent(:final cause) => ... }` reads the value it was
/// handed; `NativeShapeAbsent(NativeShapeAbsentCause.noModuleLinked)` decides
/// for itself what the build reports. Dart's named-field pattern always opens
/// with `:` or with a field name followed by `:`, so the negative lookahead for
/// `:` is positional rather than a list of shapes seen so far.
bool _buildsStatusInline(String source) => RegExp(
  r'NativeShapeAbsent\s*\(\s*(?![:)])(?![a-z]\w*\s*:)',
).hasMatch(_codeOnly(source));

List<File> _presentationFiles() {
  final root = Directory('lib');
  if (!root.existsSync()) {
    throw StateError(
      'run from apps/reference_app; cwd is '
      '${Directory.current.path}',
    );
  }
  return root
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
}

void main() {
  group('4e the absent state is on screen, derived not authored', () {
    testWidgets('4e the panel renders the value\'s own text, unconditionally', (
      tester,
    ) async {
      final expected = nativeShapeAvailabilityText(
        nativeShapeAvailabilityForThisBuild,
      );

      // Two different constructions, because "unconditional" is the
      // requirement: a row that appears only in some configuration is a row
      // that can vanish exactly when the news is bad.
      for (final panel in [
        const DiagnosticsPanel(),
        DiagnosticsPanel(seed: QualityHistory(), sourceLabel: 'unit test'),
      ]) {
        await tester.pumpWidget(
          MaterialApp(
            // The app's own theme factory, because the panel reads semantic
            // colours through a theme extension and throws without it. Building
            // a bare MaterialApp here would test a widget the app never renders.
            theme: buildAppThemeData(Brightness.light),
            home: Scaffold(body: SingleChildScrollView(child: panel)),
          ),
        );
        await tester.pump();

        expect(
          find.text(expected),
          findsOneWidget,
          reason:
              'the panel must render the status value\'s own words, with no '
              'interaction and no toggle',
        );
      }
    });

    testWidgets('4e the finder used above can fail', (tester) async {
      // Without this, a finder that matched nothing would make the test above
      // green forever.
      final expected = nativeShapeAvailabilityText(
        nativeShapeAvailabilityForThisBuild,
      );
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: SizedBox.shrink())),
      );
      expect(find.text(expected), findsNothing);
    });

    test('4e every cause states unavailability and claims nothing', () {
      // The content check that keeps "derived from the value" from meaning
      // "derived from whatever the value's translator felt like saying".
      for (final cause in NativeShapeAbsentCause.values) {
        final text = nativeShapeAvailabilityText(NativeShapeAbsent(cause));

        expect(
          text.trim(),
          isNotEmpty,
          reason: '${cause.name} renders nothing',
        );
        expect(
          text.toLowerCase(),
          contains('not available'),
          reason: '${cause.name} must state the absent state explicitly',
        );
        // No promise, no schedule: a coming-soon sentence is a claim about the
        // future that nothing in this repository can back.
        expect(
          text.toLowerCase(),
          isNot(
            anyOf(
              contains('coming soon'),
              contains('will be'),
              contains('soon'),
              matches(RegExp(r'\b20\d\d\b')),
            ),
          ),
          reason: '${cause.name} promises something',
        );
      }
    });
  });

  group('4f the wording and the state have exactly one home', () {
    test('4f prose about the capability appears in exactly one file', () {
      final withProse = <String>[];
      for (final file in _presentationFiles()) {
        if (_hasProse(file.readAsStringSync())) withProse.add(file.path);
      }
      expect(withProse, [_wordingOwner]);

      // The predicate distinguishes prose from identifiers, which is the only
      // reason the assertion above can be this strict.
      expect(_hasProse('nativeShapeAvailabilityText(status)'), isFalse);
      expect(_hasProse('class _NativeShapeAvailabilityRow'), isFalse);
      expect(_hasProse('Native shape support is not available'), isTrue);
    });

    test('4f no surface constructs the status value itself', () {
      final offenders = <String>[];
      for (final file in _presentationFiles()) {
        if (_buildsStatusInline(file.readAsStringSync())) {
          offenders.add(file.path);
        }
      }
      expect(
        offenders,
        isEmpty,
        reason:
            'a surface that builds its own status decides for itself what '
            'this build reports, which is the inversion these gates undo',
      );

      expect(
        _buildsStatusInline(
          'const status = NativeShapeAbsent(NativeShapeAbsentCause.noModuleLinked);',
        ),
        isTrue,
        reason: 'the predicate must be able to see an inline construction',
      );
    });

    test('4f the panel takes the value from the package constant', () {
      final panel = File(
        'lib/src/ui/diagnostics_panel.dart',
      ).readAsStringSync();
      expect(panel, contains('nativeShapeAvailabilityForThisBuild'));
      expect(panel, contains('nativeShapeAvailabilityText'));
      // And it reaches neither the causes nor a hand-made status.
      expect(_buildsStatusInline(panel), isFalse);
      expect(
        panel.contains('NativeShapeAbsentCause.'),
        isFalse,
        reason:
            'branching on the cause at the surface would put the wording '
            'decision back in the panel',
      );
    });

    test(
      '4f the wording owner derives from the type, with no default branch',
      () {
        final owner = File(_wordingOwner).readAsStringSync();
        // Exhaustiveness is what makes a future second member break this file
        // instead of silently rendering today's sentence for a new state.
        final code = owner
            .split('\n')
            .where((line) => !line.trimLeft().startsWith('//'))
            .join('\n');
        expect(code.contains('default:'), isFalse);
        expect(
          RegExp(r'^\s*_\s*=>', multiLine: true).hasMatch(code),
          isFalse,
          reason: 'a wildcard arm is a default branch wearing a different hat',
        );
      },
    );
  });
}
