/// Runs on the attached phone and records what the pinned backend composes
/// THERE, so a verdict that currently says one architecture can be re-measured
/// on a second one.
///
/// WHY AN INTEGRATION TEST AND NOT A HOST TOOL
/// The host instrument (tools/first_record/first_record.c) is a program with a
/// main(); a phone runs applications, not programs. The app already links the
/// backend for the device build, so the cheapest honest way to reach it on the
/// phone is to ask the running process — which is exactly what the shim exists
/// for.
///
/// WHAT IT PRINTS
/// Lines prefixed `RECORD|`, in the format tools/compare_arch_records.py reads:
/// provenance first, one hex line last. The host driver
/// (tools/capture_device_record.sh) extracts them from this test's output, so
/// nothing has to be pulled off the device.
///
/// WHAT IT ASSERTS
/// That the backend really is linked into this build, that the pin it reports
/// is the one the pod was configured with, and that the bytes look like a
/// handshake record. It deliberately does NOT assert the bytes equal the host's
/// — that comparison belongs to the comparator, under a declared projection,
/// because the configuration permutes its extension order per connection and
/// two runs on one machine already differ.
library;

import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:native_transport/native_transport.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('4-arm64 the process composes a first record on this device',
      (WidgetTester tester) async {
    final probe = ShimProbe.ofThisProcess();

    // A failure here is not a failure of the measurement — it says this build
    // has no backend to measure, which is a different fact and deserves a
    // different sentence.
    expect(probe.state, ShimProbeState.presentBackendLinked,
        reason: 'the shim reports ${probe.state}; a device build made where '
            'the pinned archives were present reports presentBackendLinked');

    final pin = probe.buildPin();
    expect(pin, isNotNull);
    expect(pin, isNotEmpty);

    final record = probe.firstRecord();
    expect(record, isNotNull, reason: 'the backend composed no bytes');
    final bytes = record!;
    expect(bytes.length, greaterThan(5));
    expect(bytes[0], 22, reason: 'first byte of a handshake record');
    expect(bytes[5], 1, reason: 'the first handshake message');

    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    final now = DateTime.now().toUtc().toIso8601String().split('.').first;

    // One line per field, marker-prefixed so the host driver can extract them
    // from a log that also carries the framework's own chatter.
    // Derived, never spelled out: a test that writes "arm64" into its own
    // output is making the claim the comparison is supposed to check. This
    // reads the architecture the code is actually executing as, so running the
    // same test on a simulator reports x86_64 and the comparison rejects it.
    final abi = Abi.current().toString();
    final arch = abi.toLowerCase().contains('arm64')
        ? 'arm64'
        : abi.toLowerCase().contains('x64')
            ? 'x86_64'
            : abi;

    final lines = <String>[
      'arch: $arch',
      'abi: $abi',
      'host: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
      'date: ${now}Z',
      'source: integration_test/first_record_on_device_test.dart via pt_shim',
      'pin: $pin',
      'bytes: ${bytes.length}',
      'hex: $hex',
    ];
    for (final line in lines) {
      // ignore: avoid_print
      print('RECORD|$line');
    }
  });
}
