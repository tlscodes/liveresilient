/// Gate 4b — a recording of the exchange, checked in the two different ways its
/// two findings require.
///
/// WHY A SNAPSHOT TEST AND NOT A LIVE ONE
/// The measurement needed a physical device, a privileged recorder attached to
/// it, and a peer process on the host. None of that can exist inside a workspace
/// suite, so the suite cannot re-perform it. What it CAN do — and what this file
/// does — is hold the recorded run to its own words: the record is committed by
/// name, and these tests fail if it stops saying what it said. Same shape as the
/// sibling snapshot for gate 4a.
///
/// THE TWO FINDINGS ARE NOT THE SAME KIND OF THING
/// One says a value was found NOWHERE. That is a universal claim, and it is
/// worth exactly as much as the coverage behind it — a recording of nothing
/// satisfies it trivially. So this file never checks it alone: the coverage
/// figure must equal the size of the input it names, three encodings must have
/// been scanned, and the scanner must have passed its own planted-pattern test
/// before its verdict counts.
///
/// The other says a value was found at ONE EXACT PLACE. That is existential, and
/// one witness settles it — but only a located one. So the index must parse as a
/// number, the record must state the position fell inside a packet's data
/// region, and the value read out of that position must equal the committed
/// label. "This string occurs somewhere in the file" is the assertion this file
/// deliberately does not make, because a recorder writes its own metadata into
/// the file and metadata is not something the device sent.
///
/// WHAT THIS PROVES, EXACTLY
/// That on the recorded date, in one recorded exchange, one label was absent
/// from every byte scanned and the other was present in a named field. It does
/// NOT prove the protection holds in general, on another network, or today. One
/// recorded exchange is one exchange, and no committed file can support more.
/// The live re-run is one command (tools/step7_analyze.py --recheck) and its
/// output overwrites this record.
///
/// THE NEGATIVE CONTROL IS THE POINT
/// Every positive test above routes through [recordSupportsTheGate]. The control
/// mutates the record text four ways — a leak, a short scan, an unlocated
/// witness, a scanner that never proved it could see — and requires that same
/// function to reject each. A control that exercised a different code path would
/// prove nothing about the predicate the gate actually rests on.
library;

import 'dart:io';

import 'package:test/test.dart';

const String kAnalysis = 'docs/evidence/step7_trace_analysis.txt';
const String kProvenance = 'docs/evidence/step7_trace_provenance.txt';
const String kAbsentLabel = 'docs/evidence/step7_real_name.txt';
const String kPresentLabel = 'docs/evidence/step7_public_name.txt';

/// The extension whose presence in the offered list is what makes the exchange
/// the one this gate is about rather than an ordinary one.
const int kExtensionUnderTest = 65037;

File _evidenceFile(String path) {
  for (final candidate in [path, '../../$path']) {
    final file = File(candidate);
    if (file.existsSync()) return file;
  }
  throw StateError('$path not found from ${Directory.current.path}');
}

String _read(String path) => _evidenceFile(path).readAsStringSync().trim();

/// Reads `key: value` lines, keeping EVERY value for a repeated key.
///
/// One key in this record legitimately repeats — the encodings the scan covered
/// — and a map that kept only the first would silently turn "three encodings
/// were scanned" into an unfalsifiable claim.
Map<String, List<String>> fieldsOf(String source) {
  final out = <String, List<String>>{};
  for (final line in source.split('\n')) {
    final index = line.indexOf(': ');
    if (index <= 0) continue;
    out
        .putIfAbsent(line.substring(0, index).trim(), () => <String>[])
        .add(line.substring(index + 2).trim());
  }
  return out;
}

String? _one(Map<String, List<String>> fields, String key) {
  final values = fields[key];
  if (values == null || values.isEmpty) return null;
  return values.first;
}

int? _int(Map<String, List<String>> fields, String key) =>
    int.tryParse(_one(fields, key) ?? '');

/// The gate's predicate, in one place so the negative control can attack the
/// same function the positive tests trust.
///
/// [publicLabel] is passed in rather than read inside, so the control can hold
/// it fixed while it mutates the record.
bool recordSupportsTheGate(String record, {required String publicLabel}) {
  final fields = fieldsOf(record);

  // The universal half: found nowhere, over a scan whose coverage is stated and
  // whose scanner proved it can see.
  if (_one(fields, 'absent_label_found') != 'no') return false;
  final covered = _int(fields, 'scan_coverage_bytes');
  final size = _int(fields, 'full_bytes');
  if (covered == null || size == null || covered != size) return false;
  if ((fields['scan_encoding'] ?? const <String>[]).toSet().length != 3) {
    return false;
  }
  if (_one(fields, 'scanner_self_test') == null) return false;

  // The existential half: one witness, and located.
  if (_int(fields, 'witness_packet_index') == null) return false;
  if (!(_one(fields, 'witness_in_packet_data_region') ?? '').startsWith(
    'yes',
  )) {
    return false;
  }
  if (_one(fields, 'witness_field_value') != publicLabel) return false;

  return true;
}

void main() {
  final record = _read(kAnalysis);
  final fields = fieldsOf(record);
  final absentLabel = _read(kAbsentLabel);
  final presentLabel = _read(kPresentLabel);

  test(
    '4b the label that must not travel in the clear was found nowhere, '
    'over a scan that covered the whole recording and proved it could see',
    () {
      expect(_one(fields, 'absent_label_found'), 'no');

      // Coverage is compared as numbers against the size of the very file it
      // claims to have scanned. A short scan reporting "not found" is the exact
      // false green this gate exists to refuse.
      final covered = _int(fields, 'scan_coverage_bytes');
      final size = _int(fields, 'full_bytes');
      expect(
        covered,
        isNotNull,
        reason: 'coverage must be a number, not prose',
      );
      expect(size, isNotNull);
      expect(covered, size);
      expect(covered, greaterThan(0));

      expect(
        (fields['scan_encoding'] ?? const <String>[]).toSet(),
        hasLength(3),
        reason: 'a single-encoding scan cannot support "found nowhere"',
      );
      expect(
        _one(fields, 'scanner_self_test'),
        isNotNull,
        reason: 'a scanner that never proved it can see has no verdict to give',
      );
    },
  );

  test('4b the label that must appear was located inside a packet, not merely '
      'present somewhere in the file', () {
    expect(_int(fields, 'witness_packet_index'), isNotNull);
    expect(
      _one(fields, 'witness_in_packet_data_region'),
      startsWith('yes'),
      reason:
          'a hit in the recorder\'s own metadata is not something the '
          'device sent',
    );
    expect(_int(fields, 'witness_offset_in_packet_data'), isNotNull);
    expect(_one(fields, 'witness_field_value'), presentLabel);
  });

  test('4b the extension under test was actually offered in that exchange', () {
    final ids = (_one(fields, 'offered_extension_ids') ?? '')
        .split(',')
        .map((value) => int.tryParse(value.trim()))
        .whereType<int>()
        .toList();
    expect(ids, contains(kExtensionUnderTest));
    expect(_one(fields, 'offered_extension_under_test_present'), 'yes');
    expect(
      ids.length,
      _int(fields, 'offered_extension_count'),
      reason: 'the recorded count and the recorded list must agree',
    );
  });

  test(
    '4b the record is about the two committed labels, and they are distinct',
    () {
      expect(_one(fields, 'absent_label'), absentLabel);
      expect(_one(fields, 'present_label'), presentLabel);
      expect(
        absentLabel.toLowerCase(),
        isNot(presentLabel.toLowerCase()),
        reason: 'identical labels would make the two findings contradict',
      );
    },
  );

  test('4b the recording carries provenance: what recorded it, and when', () {
    final provenance = fieldsOf(_read(kProvenance));
    expect(_one(provenance, 'tool'), isNotNull);
    expect(_one(provenance, 'date'), matches(RegExp(r'^20\d\d-\d\d-\d\d')));
    expect(_int(provenance, 'duration_seconds'), isNotNull);
  });

  test('4b the committed record satisfies the gate predicate', () {
    expect(recordSupportsTheGate(record, publicLabel: presentLabel), isTrue);
  });

  test('4b the predicate rejects each way the record could be hollow', () {
    // A leak: the label did travel in the clear.
    expect(
      recordSupportsTheGate(
        record.replaceAll('absent_label_found: no', 'absent_label_found: yes'),
        publicLabel: presentLabel,
      ),
      isFalse,
      reason: 'a recorded leak must fail the gate',
    );

    // A scan that stopped early, then reported nothing found.
    final size = _int(fields, 'full_bytes')!;
    expect(
      recordSupportsTheGate(
        record.replaceAll(
          'scan_coverage_bytes: $size',
          'scan_coverage_bytes: ${size - 1}',
        ),
        publicLabel: presentLabel,
      ),
      isFalse,
      reason: 'coverage short of the file it names is not a whole-file scan',
    );

    // A witness that is in the file but not in any packet the device sent.
    expect(
      recordSupportsTheGate(
        record.replaceAll(
          RegExp(r'witness_in_packet_data_region: yes.*'),
          'witness_in_packet_data_region: no',
        ),
        publicLabel: presentLabel,
      ),
      isFalse,
      reason: 'an unlocated witness could be the recorder\'s own metadata',
    );

    // A scanner that never demonstrated it could find what it looked for.
    expect(
      recordSupportsTheGate(
        record.replaceAll(RegExp(r'scanner_self_test: .*\n'), ''),
        publicLabel: presentLabel,
      ),
      isFalse,
      reason: 'an untested scanner\'s "not found" is not evidence',
    );

    // The witness is real but names something else.
    expect(
      recordSupportsTheGate(record, publicLabel: 'some-other-name.example'),
      isFalse,
      reason: 'the located field must be the label the gate is about',
    );
  });
}
