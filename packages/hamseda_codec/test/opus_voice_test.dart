// Opus mode 12 on the voice-note wire, against the vendored libopus 1.5.2
// host dylib (tools/phase5/native/opus-mac): every 60 ms frame is exactly
// 45 B in hard CBR, a 3 s voiced tone round-trips through packVoiceNote /
// unpackVoiceNote with the pitch intact, pick() prefers Opus while it
// fits, and the Lyra nibbles are refused by name.
import 'dart:math';
import 'dart:typed_data';

import 'package:hamseda_codec/src/opus_ffi.dart';
import 'package:hamseda_codec/src/voice_frame_codec.dart';
import 'package:hamseda_codec/src/voice_note_codec.dart';
import 'package:test/test.dart';

Int16List tone(double seconds, {double hz = 180, double amp = 8000}) {
  final n = (seconds * 8000).round();
  final out = Int16List(n);
  for (var i = 0; i < n; i++) {
    // a harmonic-rich "voiced" buzz: fundamental + 3 harmonics
    var v = 0.0;
    for (var h = 1; h <= 4; h++) {
      v += sin(2 * pi * hz * h * i / 8000) / h;
    }
    out[i] = (v * amp * 0.6).round().clamp(-32768, 32767);
  }
  return out;
}

/// Dominant frequency of [x] by a coarse autocorrelation peak search.
double pitchOf(Int16List x) {
  var bestLag = 0;
  var best = -1.0;
  for (var lag = 20; lag <= 200; lag++) {
    var s = 0.0;
    for (var i = 0; i + lag < x.length; i++) {
      s += x[i] * x[i + lag].toDouble();
    }
    if (s > best) {
      best = s;
      bestLag = lag;
    }
  }
  return 8000 / bestLag;
}

void main() {
  test('libopus 1.5.2 is the vendored library', () {
    expect(opusVersion(), contains('1.5.2'));
  });

  test('every 60 ms frame is exactly 45 B in hard CBR', () {
    final codec = OpusVoice();
    try {
      final x = tone(1.2);
      final per = codec.samplesPerFrame;
      expect(per, 480);
      for (var i = 0; i + per <= x.length; i += per) {
        expect(codec.encodeFrame(x.sublist(i, i + per)), hasLength(45));
      }
    } finally {
      codec.dispose();
    }
  });

  test('3 s voiced tone round-trips the wire with its pitch intact', () {
    final enc = voiceFrameCodecFor(VoiceNoteMode.opus6k);
    final dec = voiceFrameCodecFor(VoiceNoteMode.opus6k);
    try {
      final x = tone(3);
      final per = enc.samplesPerFrame;
      final frames = <Uint8List>[
        for (var i = 0; i + per <= x.length; i += per)
          enc.encodeFrame(x.sublist(i, i + per)),
      ];
      expect(frames, hasLength(50));
      final wire = packVoiceNote(frames: frames, mode: VoiceNoteMode.opus6k);
      expect(wire.length, 4 + 50 * 45);
      expect(wire[0] & 0x0F, 12);
      expect(voiceNoteModeOf(wire), VoiceNoteMode.opus6k);
      final back = unpackVoiceNote(wire);
      expect(back, hasLength(50));
      final pcm = BytesBuilder();
      for (final f in back) {
        final s = dec.decodeFrame(f);
        pcm.add(s.buffer.asUint8List(s.offsetInBytes, s.lengthInBytes));
      }
      final y = Int16List.sublistView(pcm.takeBytes());
      expect(y, hasLength(50 * 480));
      // skip the first 0.5 s (encoder warm-up), then the pitch must hold
      final tail = y.sublist(4000);
      expect(pitchOf(tail), closeTo(180, 6));
      var e = 0.0;
      for (final s in tail) {
        e += s * s.toDouble();
      }
      expect(sqrt(e / tail.length), greaterThan(1500));
    } finally {
      enc.dispose();
      dec.dispose();
    }
  });

  test('pick prefers Opus 6k while it fits ten letters', () {
    const budget = 10 * (4096 - 29);
    expect(
      VoiceNoteMode.pick(const Duration(seconds: 30), budget),
      VoiceNoteMode.opus6k,
    );
    expect(
      VoiceNoteMode.pick(const Duration(seconds: 54), budget),
      VoiceNoteMode.opus6k,
    );
    expect(
      VoiceNoteMode.pick(const Duration(seconds: 55), budget),
      VoiceNoteMode.c3200,
    );
    expect(VoiceNoteMode.opus6k.bytesPerSecond, 750);
  });

  test('the Lyra nibbles and the extension escape are refused by name', () {
    for (final nib in const [13, 14, 15]) {
      final wire = Uint8List.fromList([0x10 | nib, 1, 0, 0, 0, 0, 0, 0]);
      expect(
        () => voiceNoteModeOf(wire),
        throwsA(
          isA<MalformedVoiceNote>().having(
            (e) => e.reason,
            'reason',
            contains('reserved'),
          ),
        ),
      );
    }
  });
}
