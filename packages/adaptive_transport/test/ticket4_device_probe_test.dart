/// Gate 4a — the module linked into the application reached a peer that offers
/// the extension, and the peer honoured the configuration it was given.
///
/// WHY A SNAPSHOT TEST AND NOT A LIVE ONE
/// The measurement needs a physical phone with the module linked, a helper
/// process running on the host, and a cable between them. None of that can exist
/// inside a workspace suite, so the suite cannot re-perform it. What the suite
/// CAN do — and what this file does — is hold the recorded run to its own words:
/// the evidence is committed by name, and these tests fail if it stops saying
/// what it said. That is the same shape as the replay snapshot test for gate 2c.
///
/// WHAT THIS PROVES, EXACTLY
/// That on the recorded date, on the recorded device, the probe answered
/// `applied` against a peer whose public name differs from the name the device
/// asked for. It does NOT prove the capability works on any device today, and it
/// cannot: a test that claimed that would be claiming something no committed
/// file can support. The live re-run is one command
/// (`tools/probe_device_ech.sh`) and its output overwrites this evidence.
///
/// THE NEGATIVE CONTROL IS THE POINT
/// `applied` and `ignored` both mean the exchange finished. A gate that accepted
/// either would pass against a peer that did nothing with the configuration,
/// which is precisely the false green this ticket exists to avoid — so the
/// predicate here rejects every outcome except `applied`, and proves it can.
library;

import 'dart:io';

import 'package:test/test.dart';

const String kEvidence = 'docs/evidence/step6_probe_answer.txt';

File _evidenceFile() {
  for (final candidate in [kEvidence, '../../$kEvidence']) {
    final file = File(candidate);
    if (file.existsSync()) return file;
  }
  throw StateError('$kEvidence not found from ${Directory.current.path}');
}

/// Reads `key: value` lines. The evidence is written by a shell driver, so the
/// format is deliberately the dullest thing that survives a clone.
Map<String, String> _fields(String source) {
  final out = <String, String>{};
  for (final line in source.split('\n')) {
    final index = line.indexOf(': ');
    if (index <= 0) continue;
    out.putIfAbsent(line.substring(0, index).trim(), () => line.substring(index + 2).trim());
  }
  return out;
}

/// The gate's predicate: the recorded run finished AND the peer used what it was
/// given. Written as an equality against one value rather than a "not a failure"
/// check, because the near-miss this gate guards against is a success.
bool _peerHonouredTheConfiguration(Map<String, String> fields) =>
    fields['outcome'] == 'applied';

void main() {
  final source = _evidenceFile().readAsStringSync();
  final fields = _fields(source);

  group('4a the linked module reached a peer that offers the extension', () {
    test('4a the recorded probe answered applied, on a real device', () {
      expect(_peerHonouredTheConfiguration(fields), isTrue,
          reason: 'the recorded outcome is ${fields['outcome']}');

      expect(fields['device'], isNotNull);
      expect(fields['device'], isNotEmpty,
          reason: 'a probe answer with no device is not a device measurement');
      expect(fields['source'], contains('pt_shim_ech_probe'),
          reason: 'the answer must come from the linked module, not from Dart');
      expect(fields['build_pin'], isNotEmpty,
          reason: 'the module must say which revision answered');
    });

    test('4a the peer offered a public name different from the one asked for',
        () {
      final asked = fields['inner_name_asked_for'];
      final public = fields['helper_public_name'];

      expect(asked, isNotNull);
      expect(public, isNotNull);
      expect(asked, isNot(equals(public)),
          reason: 'if the two names are the same there is nothing for the '
              'extension to do, and a green here would mean nothing');
      expect(fields['peer'], contains(':'),
          reason: 'the address the device actually reached is part of the '
              'record; a measurement with no peer is not one');
    });

    test('4a the predicate rejects a finished exchange the peer ignored', () {
      // The negative control, on synthetic records the predicate has never
      // seen. `ignored` is the dangerous one: the exchange completed, so any
      // check phrased as "no error" would call it a pass.
      for (final outcome in ['ignored', 'rejected', 'timedOut', 'unreachable',
        'noBackendInThisProcess', 'internalFailure']) {
        expect(
          _peerHonouredTheConfiguration({'outcome': outcome}),
          isFalse,
          reason: '$outcome must not satisfy this gate',
        );
      }
      expect(_peerHonouredTheConfiguration({'outcome': 'applied'}), isTrue);
      expect(_peerHonouredTheConfiguration(const {}), isFalse,
          reason: 'a missing outcome is not a pass');
    });

    test('4a the evidence names the route, because the first answer was wrong',
        () {
      // Recorded because the first device run answered `unreachable` against a
      // wired LAN address the phone had no path to. The address is part of the
      // measurement's meaning: without it, a later reader cannot tell a working
      // capability from a working network.
      expect(source, contains('192.168.2.1'),
          reason: 'the evidence must name the address that actually worked');
      expect(source.toLowerCase(), contains('bridge'),
          reason: 'the route that made it reachable is part of the record');
    });
  });
}
