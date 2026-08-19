import 'dart:typed_data';

import 'package:adaptive_transport/src/ptt_engine.dart';
import 'package:test/test.dart';

Uint8List _frame(int seed) {
  final f = Uint8List(4);
  f[0] = seed & 0xFF;
  f[1] = (seed * 7) & 0xFF;
  f[2] = (seed * 13) & 0xFF;
  f[3] = ((seed * 29) & 0xF0);
  return f;
}

void main() {
  test('4s bundle of 700C is exactly 2B tag + 350B payload', () {
    final sent = <Uint8List>[];
    final b = PttBundler(
        tag: 0x1234, bundle: const Duration(seconds: 4), send: sent.add);
    expect(b.framesPerBundle, 100);
    expect(b.bundleWireBytes, 352);
    for (var i = 0; i < 100; i++) {
      b.addFrame(_frame(i));
    }
    expect(sent, hasLength(1));
    expect(sent.single.length, 352);
    expect(sent.single[0], 0x12);
    expect(sent.single[1], 0x34);
  });

  test('bundle -> unbundle round-trips every frame exactly', () {
    final sent = <Uint8List>[];
    final b = PttBundler(
        tag: 0xBEEF, bundle: const Duration(seconds: 2), send: sent.add);
    final frames = List.generate(50, _frame);
    frames.forEach(b.addFrame);
    final back = PttUnbundler().accept(sent.single);
    expect(back.length, 50);
    for (var i = 0; i < 50; i++) {
      expect(back[i], frames[i], reason: 'frame $i');
    }
  });

  test('PTT release flushes a partial bundle immediately', () {
    final sent = <Uint8List>[];
    final b = PttBundler(
        tag: 1, bundle: const Duration(seconds: 4), send: sent.add);
    b.addFrame(_frame(9));
    expect(sent, isEmpty);
    b.flush();
    expect(sent, hasLength(1));
    expect(sent.single.length, pttTagBytes + 4); // ceil(28/8)=4
  });

  test('sub-second and oversized bundles are rejected by construction', () {
    expect(
        () => PttBundler(
            tag: 1,
            bundle: const Duration(milliseconds: 160),
            send: (_) {}),
        throwsA(isA<PttConfigError>()));
    expect(
        () => PttBundler(
            tag: 1, bundle: const Duration(seconds: 5), send: (_) {}),
        throwsA(isA<PttConfigError>()));
  });

  test('receive queue is bounded: oldest bundles drop, depth never grows', () {
    final sent = <Uint8List>[];
    final b = PttBundler(
        tag: 2, bundle: const Duration(seconds: 1), send: sent.add);
    final u = PttUnbundler(maxQueued: 3);
    for (var k = 0; k < 10; k++) {
      for (var i = 0; i < 25; i++) {
        b.addFrame(_frame(k * 25 + i));
      }
    }
    expect(sent, hasLength(10));
    for (final d in sent) {
      u.accept(d);
    }
    expect(u.queuedBundles, 3);
  });
}
