import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Ticket 6 gate 6b — the resolver seam cannot be omitted by accident.
///
/// The measured defect: an optional nullable resolver that nobody ever
/// supplied. It sat null in production for months while the code read as
/// though the capability existed, and it was found only by tracing the
/// argument by hand.
///
/// The resolution is two statements at two layers, both true at once. At the
/// library boundary the parameter stays optional, so the package compiles
/// standalone and the platform's own behaviour stays deliberately reachable.
/// At the composition root every construction site must name a value — and
/// choosing the platform is done by naming `platformHostResolution`, not by
/// leaving the argument out. What becomes impossible is the unstated
/// omission, never the opt-out itself.
///
/// This test is the mechanical half. Without it the rule is a convention, and
/// a convention is what failed the first time.
void main() {
  final root = Directory.current.path;

  /// Every `.dart` under `lib/`, which is the composition root's own code.
  /// Test files are excluded on purpose: a test that constructs a session to
  /// exercise something else is not a production wiring site.
  List<File> libSources() => Directory('$root/lib')
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .toList();

  /// Splits [source] into the argument text of each call to [callee].
  ///
  /// Brace/paren counting rather than a regex, because an argument list here
  /// contains nested calls, closures and collection literals, and a regex
  /// that "mostly works" on those would silently under-report — which is the
  /// same class of failure this whole gate exists to prevent.
  List<String> callArguments(String source, String callee) {
    final out = <String>[];
    var index = 0;
    while (true) {
      final start = source.indexOf('$callee(', index);
      if (start < 0) break;
      var depth = 0;
      var i = start + callee.length;
      final open = i;
      for (; i < source.length; i++) {
        final c = source[i];
        if (c == '(') depth++;
        if (c == ')') {
          depth--;
          if (depth == 0) break;
        }
      }
      if (i >= source.length) break;
      out.add(source.substring(open + 1, i));
      index = i + 1;
    }
    return out;
  }

  group('gate 6b — resolver wiring', () {
    test('every session construction site names the resolver', () {
      final offenders = <String>[];
      for (final file in libSources()) {
        final source = file.readAsStringSync();
        // The declaration itself is not a construction site.
        if (file.path.endsWith('call_session.dart')) continue;
        for (final args in callArguments(source, 'buildWebRtcCallSession')) {
          if (!args.contains('resolveAddress:')) {
            offenders.add(file.path.replaceFirst(root, ''));
          }
        }
      }
      expect(
        offenders,
        isEmpty,
        reason: 'these sites construct a session without naming the resolver, '
            'which is the omission that used to be invisible: $offenders',
      );
    });

    test('every socket construction site names the resolver', () {
      final offenders = <String>[];
      for (final file in libSources()) {
        if (file.path.endsWith('ws_connector.dart')) continue;
        final source = file.readAsStringSync();
        for (final args in callArguments(
          source,
          'connectWebSocketWithCustomRules',
        )) {
          if (!args.contains('hostResolver:')) {
            offenders.add(file.path.replaceFirst(root, ''));
          }
        }
      }
      expect(offenders, isEmpty, reason: 'unwired socket sites: $offenders');
    });

    test(
      'a wrapper may not bake in the platform default, which would rebuild '
      'the same defect one layer up',
      () {
        // A wrapper that hardcodes the choice satisfies the argument check
        // above while taking the decision away from its own callers. The
        // rule: any lib/ function that both accepts a resolver AND passes
        // one on must pass its OWN parameter, not a hardcoded value.
        final offenders = <String>[];
        for (final file in libSources()) {
          if (file.path.endsWith('main.dart')) continue; // the root itself
          final source = file.readAsStringSync();
          final acceptsSeam = source.contains(
            'Future<String?> Function(String host)?',
          );
          if (!acceptsSeam) continue;
          for (final args in callArguments(source, 'buildWebRtcCallSession')) {
            if (args.contains('resolveAddress: platformHostResolution')) {
              offenders.add(file.path.replaceFirst(root, ''));
            }
          }
        }
        expect(
          offenders,
          isEmpty,
          reason: 'these wrappers accept a resolver and then ignore it in '
              'favour of the platform default: $offenders',
        );
      },
    );

    test('the deliberate opt-out is a named, greppable value', () {
      final connector = File(
        '$root/lib/src/ws_connector.dart',
      ).readAsStringSync();
      expect(
        connector,
        contains('platformHostResolution'),
        reason: 'choosing the platform must be sayable, or silence and '
            'choice stay indistinguishable',
      );
    });
  });
}
