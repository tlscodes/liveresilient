// Mode 6 (Opus SILK VBR, 60 ms, 16 kHz, length-prefixed) against the
// vendored libopus 1.5.2 host dylib: packets are 1..255 B and vary, a 3 s
// voiced tone round-trips the variable wire with its pitch intact at
// 16 kHz, the NoLACE decode (complexity 7) differs from the plain decode
// on a wideband packet (OSCE compiled in) and never on mode 12, a
// truncated wire is refused by name, and pick() never returns the
// variable mode.
import 'dart:math';
import 'dart:typed_data';

import 'package:hamseda_codec/src/opus_ffi.dart';
import 'package:hamseda_codec/src/voice_frame_codec.dart';
import 'package:hamseda_codec/src/voice_note_codec.dart';
import 'package:test/test.dart';

Int16List tone(double seconds, int rate, {double hz = 180, double amp = 8000}) {
  final n = (seconds * rate).round();
  final out = Int16List(n);
  for (var i = 0; i < n; i++) {
    var v = 0.0;
    for (var h = 1; h <= 6; h++) {
      v += sin(2 * pi * hz * h * i / rate) / h;
    }
    out[i] = (v * amp * 0.5).round().clamp(-32768, 32767);
  }
  return out;
}

double pitchOf(Int16List x, int rate) {
  var bestLag = 0;
  var best = -1.0;
  for (var lag = rate ~/ 400; lag <= rate ~/ 40; lag++) {
    var s = 0.0;
    for (var i = 0; i + lag < x.length; i++) {
      s += x[i] * x[i + lag].toDouble();
    }
    if (s > best) {
      best = s;
      bestLag = lag;
    }
  }
  return rate / bestLag;
}

List<Uint8List> encodeAll(VoiceFrameCodec c, Int16List x) {
  final per = c.samplesPerFrame;
  return [
    for (var i = 0; i + per <= x.length; i += per)
      c.encodeFrame(x.sublist(i, i + per)),
  ];
}

Int16List decodeAll(VoiceFrameCodec c, List<Uint8List> frames) {
  final pcm = BytesBuilder();
  for (final f in frames) {
    final s = c.decodeFrame(f);
    pcm.add(s.buffer.asUint8List(s.offsetInBytes, s.lengthInBytes));
  }
  return Int16List.sublistView(pcm.takeBytes());
}

void main() {
  test('mode 6 packets are variable, 1..255 B, wideband at 10 kbit/s', () {
    final enc = voiceFrameCodecFor(VoiceNoteMode.opusVbr, opusBitrate: 10000);
    try {
      expect(enc.sampleRate, 16000);
      expect(enc.samplesPerFrame, 960);
      final frames = encodeAll(enc, tone(3, 16000));
      expect(frames, hasLength(50));
      final sizes = frames.map((f) => f.length).toSet();
      expect(sizes.length, greaterThan(1), reason: 'VBR must vary');
      for (final f in frames) {
        expect(f.length, inInclusiveRange(1, 255));
        // TOC config 0..11 = SILK; 8..11 = SILK WB; frame size code 60 ms.
        final config = f[0] >> 3;
        expect(config, inInclusiveRange(8, 11), reason: 'SILK wideband TOC');
      }
      final bytes = frames.fold(0, (a, f) => a + f.length);
      // 3 s at ~10 kbit/s: 3750 B target, VBR lands within a wide band.
      expect(bytes, inInclusiveRange(1500, 4500));
    } finally {
      enc.dispose();
    }
  });

  test('3 s tone round-trips the length-prefixed wire at 16 kHz', () {
    final enc = voiceFrameCodecFor(VoiceNoteMode.opusVbr, opusBitrate: 10000);
    final dec = voiceFrameCodecFor(VoiceNoteMode.opusVbr);
    try {
      final frames = encodeAll(enc, tone(3, 16000));
      final wire = packVoiceNote(frames: frames, mode: VoiceNoteMode.opusVbr);
      expect(wire[0] & 0x0F, 6);
      expect(voiceNoteModeOf(wire), VoiceNoteMode.opusVbr);
      expect(
        wire.length,
        4 + frames.length + frames.fold(0, (a, f) => a + f.length),
      );
      final back = unpackVoiceNote(wire);
      expect(back, hasLength(frames.length));
      for (var i = 0; i < frames.length; i++) {
        expect(back[i], equals(frames[i]));
      }
      final y = decodeAll(dec, back);
      expect(y, hasLength(50 * 960));
      expect(pitchOf(y.sublist(8000), 16000), closeTo(180, 6));
    } finally {
      enc.dispose();
      dec.dispose();
    }
  });

  test('NoLACE changes a wideband decode and never a mode-12 decode', () {
    final enc = voiceFrameCodecFor(VoiceNoteMode.opusVbr, opusBitrate: 10000);
    final plain = voiceFrameCodecFor(VoiceNoteMode.opusVbr);
    final nolace = voiceFrameCodecFor(
      VoiceNoteMode.opusVbr,
      decoderComplexity: 7,
    );
    final enc12 = voiceFrameCodecFor(VoiceNoteMode.opus6k);
    final plain12 = voiceFrameCodecFor(VoiceNoteMode.opus6k);
    final nolace12 = voiceFrameCodecFor(
      VoiceNoteMode.opus6k,
      decoderComplexity: 7,
    );
    try {
      final frames = encodeAll(enc, tone(2, 16000));
      final a = decodeAll(plain, frames);
      final b = decodeAll(nolace, frames);
      expect(a, hasLength(b.length));
      var diff = 0;
      for (var i = 0; i < a.length; i++) {
        if (a[i] != b[i]) diff++;
      }
      expect(diff, greaterThan(a.length ~/ 10), reason: 'OSCE ran on WB');
      final f12 = encodeAll(enc12, tone(2, 8000));
      expect(decodeAll(plain12, f12), equals(decodeAll(nolace12, f12)));
    } finally {
      for (final c in [enc, plain, nolace, enc12, plain12, nolace12]) {
        c.dispose();
      }
    }
  });

  test('a truncated or empty-packet wire is refused by name', () {
    final good = packVoiceNote(
      frames: [
        Uint8List.fromList([0x48, 1, 2, 3]),
        Uint8List.fromList([0x48, 9]),
      ],
      mode: VoiceNoteMode.opusVbr,
    );
    expect(unpackVoiceNote(good), hasLength(2));
    final cut = Uint8List.sublistView(good, 0, good.length - 1);
    expect(
      () => unpackVoiceNote(cut),
      throwsA(
        isA<MalformedVoiceNote>().having(
          (e) => e.reason,
          'reason',
          contains('frame 1'),
        ),
      ),
    );
    expect(
      () => packVoiceNote(frames: [Uint8List(0)], mode: VoiceNoteMode.opusVbr),
      throwsA(isA<MalformedVoiceNote>()),
    );
    expect(
      () =>
          packVoiceNote(frames: [Uint8List(256)], mode: VoiceNoteMode.opusVbr),
      throwsA(isA<MalformedVoiceNote>()),
    );
  });

  test('pick never returns the variable mode; mode 12 stays byte-exact', () {
    for (final s in const [1, 30, 54, 55, 300]) {
      expect(
        VoiceNoteMode.pick(Duration(seconds: s), 10 * 4067),
        isNot(VoiceNoteMode.opusVbr),
      );
    }
    expect(VoiceNoteMode.opusVbr.isVariable, isTrue);
    expect(VoiceNoteMode.opus6k.isVariable, isFalse);
    expect(VoiceNoteMode.opus6k.sampleRate, 8000);
    expect(VoiceNoteMode.opusVbr.sampleRate, 16000);
    expect(OpusVoiceConfig.cbr6kNb.cbrBytes, 45);
    expect(OpusVoiceConfig.vbr(10000).bandwidth, 1103);
    expect(OpusVoiceConfig.vbr(8800).bandwidth, 1101);
  });
}
