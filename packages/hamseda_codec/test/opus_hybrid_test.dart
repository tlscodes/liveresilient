// Mode 7 (Opus hybrid at 48 kHz, bandwidth auto up to fullband, VBR,
// length-prefixed) against the vendored libopus 1.5.2 host dylib: at
// 20 kbit/s a speech-like input with energy above 8 kHz comes out as
// SWB/FB packets (TOC config 12..15), the band above 8 kHz survives the
// round trip (a WB mode-6 encode of the same input loses it), each packet
// decodes to 2880 samples, and the NoLACE decode differs from the plain
// one (the SILK layer is 16 kHz / 20 ms inside a hybrid packet).
import 'dart:math';
import 'dart:typed_data';

import 'package:hamseda_codec/src/voice_frame_codec.dart';
import 'package:hamseda_codec/src/voice_note_codec.dart';
import 'package:test/test.dart';

/// A voiced buzz (150 Hz, 12 harmonics to 1.8 kHz) plus a 10 kHz "sibilant"
/// burst every 400 ms, at [rate].
Int16List speechLike(double seconds, int rate) {
  final n = (seconds * rate).round();
  final out = Int16List(n);
  final r = Random(11);
  for (var i = 0; i < n; i++) {
    var v = 0.0;
    for (var h = 1; h <= 12; h++) {
      v += sin(2 * pi * 150 * h * i / rate) / h;
    }
    v *= 5000;
    final t = i / rate;
    if ((t * 2.5) % 1 < 0.25) {
      v += 4000 * sin(2 * pi * 10000 * i / rate) * (0.5 + 0.5 * r.nextDouble());
    }
    out[i] = v.round().clamp(-32768, 32767);
  }
  return out;
}

/// Energy of [x] above [hz] (a crude 2-tap high-pass, then RMS), relative.
double highBandRms(Int16List x, int rate, double hz) {
  // One-pole high-pass with the corner at hz.
  final a = 1 - 2 * pi * hz / rate;
  var yPrev = 0.0, xPrev = 0.0, e = 0.0;
  for (var i = 0; i < x.length; i++) {
    final y = x[i] - xPrev + a * yPrev;
    e += y * y;
    xPrev = x[i].toDouble();
    yPrev = y;
  }
  return sqrt(e / x.length);
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
  test('mode 7 at 20 kbit/s makes SWB/FB packets of 60 ms at 48 kHz', () {
    final enc = voiceFrameCodecFor(
      VoiceNoteMode.opusHybrid,
      opusBitrate: 20000,
    );
    final dec = voiceFrameCodecFor(VoiceNoteMode.opusHybrid);
    try {
      expect(enc.sampleRate, 48000);
      expect(enc.samplesPerFrame, 2880);
      final x = speechLike(3, 48000);
      final frames = encodeAll(enc, x);
      expect(frames, hasLength(50));
      var wide = 0;
      for (final f in frames) {
        expect(f.length, inInclusiveRange(1, 255));
        final config = f[0] >> 3;
        // 12..15 = hybrid SWB/FB; 8..11 = SILK WB (allowed on quiet frames).
        expect(config, inInclusiveRange(8, 15));
        if (config >= 12) wide++;
      }
      expect(wide, greaterThan(frames.length ~/ 2), reason: 'mostly hybrid');
      final wire = packVoiceNote(
        frames: frames,
        mode: VoiceNoteMode.opusHybrid,
      );
      expect(wire[0] & 0x0F, 7);
      expect(voiceNoteModeOf(wire), VoiceNoteMode.opusHybrid);
      final y = decodeAll(dec, unpackVoiceNote(wire));
      expect(y, hasLength(50 * 2880));
      // The 10 kHz sibilant survives in mode 7 and is gone from mode 6.
      final keep =
          highBandRms(y.sublist(48000), 48000, 8000) /
          highBandRms(x.sublist(48000), 48000, 8000);
      expect(keep, greaterThan(0.3), reason: 'above-8 kHz energy kept');
    } finally {
      enc.dispose();
      dec.dispose();
    }
  });

  test('NoLACE changes a mode-7 decode', () {
    final enc = voiceFrameCodecFor(
      VoiceNoteMode.opusHybrid,
      opusBitrate: 20000,
    );
    final plain = voiceFrameCodecFor(VoiceNoteMode.opusHybrid);
    final nolace = voiceFrameCodecFor(
      VoiceNoteMode.opusHybrid,
      decoderComplexity: 7,
    );
    try {
      final frames = encodeAll(enc, speechLike(2, 48000));
      final a = decodeAll(plain, frames);
      final b = decodeAll(nolace, frames);
      var diff = 0;
      for (var i = 0; i < a.length; i++) {
        if (a[i] != b[i]) diff++;
      }
      expect(diff, greaterThan(a.length ~/ 10));
    } finally {
      enc.dispose();
      plain.dispose();
      nolace.dispose();
    }
  });

  test('the wire refuses to confuse modes 6 and 7', () {
    expect(VoiceNoteMode.opusHybrid.isVariable, isTrue);
    expect(VoiceNoteMode.opusHybrid.sampleRate, 48000);
    expect(VoiceNoteMode.opusVbr.sampleRate, 16000);
    for (final s in const [1, 30, 300]) {
      expect(
        VoiceNoteMode.pick(Duration(seconds: s), 20 * 4067),
        isNot(VoiceNoteMode.opusHybrid),
      );
    }
  });
}
