/// Asks the phone's own process to exchange with a cooperating peer and report
/// what that peer did with the configuration it was offered.
///
/// This is the question step 6 of docs/PLAN_REMAINING.md waits on: the sealed
/// availability type gains its second member only if a run-time probe answers
/// yes, and this is that probe, run where it matters — on the device, through
/// the linked backend, against a peer that really speaks the extension.
///
/// The peer's address and configuration arrive as --dart-define values from
/// tools/probe_device_ech.sh, which reads them out of the recorded helper
/// configuration. Nothing is hardcoded here, so a test that passes cannot be
/// passing against a peer that was never started.
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:native_transport/native_transport.dart';

const String _host = String.fromEnvironment('PROBE_HOST');
const int _port = int.fromEnvironment('PROBE_PORT');
const String _configHex = String.fromEnvironment('PROBE_CONFIG_HEX');
const String _innerName = String.fromEnvironment('PROBE_INNER_NAME');

Uint8List _decodeHex(String hex) {
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // Deliberately NOT named after gate 4a. The gate ledger reads a test whose
  // name starts with a gate id as that gate's proof, and this test is a probe
  // the gate depends on, not the gate itself — naming it "4a…" made the ratchet
  // fail as stale within minutes, which is the ledger working exactly as built.
  testWidgets('probe: the peer applies the configuration this build offers', (
    WidgetTester tester,
  ) async {
    expect(_host, isNotEmpty, reason: 'PROBE_HOST was not defined');
    expect(_port, greaterThan(0), reason: 'PROBE_PORT was not defined');
    expect(_configHex, isNotEmpty, reason: 'PROBE_CONFIG_HEX was not defined');
    expect(_innerName, isNotEmpty, reason: 'PROBE_INNER_NAME was not defined');

    final probe = ShimProbe.ofThisProcess();
    expect(
      probe.state,
      ShimProbeState.presentBackendLinked,
      reason: 'this build has no backend to ask',
    );

    final outcome = probe.echProbe(
      host: _host,
      port: _port,
      configList: _decodeHex(_configHex),
      innerName: _innerName,
      timeout: const Duration(seconds: 15),
    );

    // ignore: avoid_print
    print('PROBE|outcome: ${outcome.name}');
    // ignore: avoid_print
    print('PROBE|peer: $_host:$_port');
    // ignore: avoid_print
    print('PROBE|inner_name_asked_for: $_innerName');
    // ignore: avoid_print
    print('PROBE|build_pin: ${probe.buildPin()}');

    // `ignored` is the interesting near-miss: the exchange finished, so a test
    // that only checked for completion would call it a pass, and the capability
    // would be reported as present on the strength of a peer that did nothing
    // with it.
    expect(
      outcome,
      EchProbeOutcome.applied,
      reason:
          'the peer answered $outcome; only `applied` means the '
          'configuration this build offered was actually honoured',
    );
  });
}
