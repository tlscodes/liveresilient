/// The probe's honest-absence path, which is the only path a host test process
/// can exercise: nothing here links the shim, so every question must come back
/// as "there is nothing in this process to ask" rather than as an exception.
///
/// This is the branch that runs on every developer machine and in the workspace
/// suite, so it is the branch most likely to rot unnoticed if it throws.
library;

import 'dart:typed_data';

import 'package:native_transport/native_transport.dart';
import 'package:test/test.dart';

void main() {
  group('ShimProbe on a process with no shim linked', () {
    test(
      'constructing one does not throw, and reports the symbols are absent',
      () {
        final probe = ShimProbe.ofThisProcess();
        expect(probe.state, ShimProbeState.symbolsAbsent);
        expect(probe.backendLinked, isFalse);
      },
    );

    test('every question answers nothing rather than throwing', () {
      final probe = ShimProbe.ofThisProcess();
      expect(probe.buildPin(), isNull);
      expect(probe.firstRecord(), isNull);
      expect(
        probe.echProbe(
          host: '127.0.0.1',
          port: 1,
          configList: Uint8List.fromList(const [1, 2, 3]),
          innerName: 'nowhere.example',
          timeout: const Duration(milliseconds: 1),
        ),
        EchProbeOutcome.noBackendInThisProcess,
      );
    });

    test('a probe that cannot ask is distinguishable from one that asked and '
        'got no', () {
      // The two facts a caller must never confuse: nothing to ask, versus asked
      // and told no. They are different enum members precisely so a caller
      // cannot collapse them, and this test fails if they are ever merged.
      expect(
        ShimProbeState.symbolsAbsent,
        isNot(ShimProbeState.presentBackendUnlinked),
      );
      expect(
        EchProbeOutcome.noBackendInThisProcess,
        isNot(EchProbeOutcome.ignored),
      );
      expect(EchProbeOutcome.applied, isNot(EchProbeOutcome.ignored));
    });
  });
}
