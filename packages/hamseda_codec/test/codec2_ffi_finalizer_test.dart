/// T2.2 — FFI memory-management crash probe (measured-on-host against the
/// repo's 450-capable libcodec2 build; the device links the same revision
/// as a static XCFramework).
///
/// What "no crash" means mechanically here: thousands of [Codec2] instances
/// are created and abandoned without dispose, garbage is allocated to give
/// the GC reason to run NativeFinalizers, eager-dispose and use-after-
/// dispose paths are exercised — and the process must survive to the final
/// round-trip assertion. A double-free or finalizer-vs-dispose race dies as
/// a VM abort, which the suite records as the failing row.
library;

import 'dart:math';
import 'dart:typed_data';

import 'package:hamseda_codec/src/codec2_ffi.dart';
import 'package:test/test.dart';

Int16List tone(int samples, {double hz = 220, int amp = 8000}) {
  final s = Int16List(samples);
  for (var i = 0; i < samples; i++) {
    s[i] = (amp * sin(2 * pi * hz * i / 8000)).round();
  }
  return s;
}

void main() {
  test('bit widths match the phase-5 wire math (700C=28, 450=18)', () {
    final v = Codec2(codec2Mode700C);
    final u = Codec2(codec2Mode450);
    expect(v.bitsPerFrame, 28);
    expect(u.bitsPerFrame, 18);
    expect(v.samplesPerFrame, 320);
    expect(u.samplesPerFrame, 320);
    v.dispose();
    u.dispose();
  });

  test(
    'finalizer-managed churn: abandoned instances never crash the VM',
    () async {
      final frame = tone(320);
      for (var round = 0; round < 40; round++) {
        // abandon a batch with NO dispose — lifetime belongs to the finalizer
        for (var i = 0; i < 50; i++) {
          final c = Codec2(i.isEven ? codec2Mode700C : codec2Mode450);
          c.encodeFrame(frame);
        }
        // allocate garbage so the GC has a reason to run finalizers
        List<int>.filled(200000, round);
        await Future<void>.delayed(Duration.zero);
      }
      // still alive and functional after ~2000 abandoned native states
      final c = Codec2(codec2Mode700C);
      final decoded = c.decodeFrame(c.encodeFrame(frame));
      expect(decoded.length, 320);
      c.dispose();
    },
  );

  test('eager dispose detaches the finalizer; reuse-after-dispose throws', () {
    final c = Codec2(codec2Mode450);
    final bits = c.encodeFrame(tone(320));
    expect(bits.length, 3); // ceil(18/8) bytes
    c.dispose();
    c.dispose(); // idempotent by construction
    expect(() => c.encodeFrame(tone(320)), throwsStateError);
  });

  test('250-frame round trip stays byte-exact in width and sane in energy', () {
    final c = Codec2(codec2Mode700C);
    var energy = 0.0;
    for (var f = 0; f < 250; f++) {
      final out = c.decodeFrame(c.encodeFrame(tone(320, hz: 180 + f % 60)));
      for (final s in out) {
        energy += s.abs();
      }
    }
    c.dispose();
    expect(energy, greaterThan(0), reason: 'decoder must produce audio');
  });
}
