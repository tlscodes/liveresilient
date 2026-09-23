/// SVT-AV1 encoder over Dart FFI: the phone-authored video letter
/// (2026-09-21). Tightly packed I420 frames go in, AV1 temporal units come
/// out — the list [VideoNote.videoFrames] takes — with the Mac script's
/// exact knobs (tools/t2/make_video_letter.sh v3) passed by name through
/// svt_av1_enc_parse_parameter, so the phone and the Mac make the same
/// letter. [encodeVideoLetter] then bisects crf (step 1, as the Mac) until
/// the whole wire, Opus 6k audio tail included, fits the letters.
///
/// Library resolution mirrors av1_decoder.dart: SVTAV1_LIB_PATH env var,
/// the vendored ios framework, the Homebrew dylib (4.2.0 — the struct
/// layout is version-specific, the same version the framework was built
/// from), then the process.
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
// The audio tail of a video letter: Opus SILK VBR wideband, one length
// byte per 60 ms packet (nibble 6).
// ignore: implementation_imports
import 'package:hamseda_codec/src/opus_ffi.dart';

import 'avif_writer.dart';
import 'generated/svtav1_bindings.dart';
import 'video_note_codec.dart';

DynamicLibrary _open() {
  final env = Platform.environment['SVTAV1_LIB_PATH'];
  if (env != null && env.isNotEmpty) return DynamicLibrary.open(env);
  if (Platform.isIOS)
    return DynamicLibrary.open('SvtAv1Enc.framework/SvtAv1Enc');
  for (final p in [
    '/usr/local/lib/libSvtAv1Enc.4.dylib',
    '/opt/homebrew/lib/libSvtAv1Enc.4.dylib',
  ]) {
    if (File(p).existsSync()) return DynamicLibrary.open(p);
  }
  return DynamicLibrary.process();
}

final SvtAv1Bindings _b = SvtAv1Bindings(_open());

/// libSvtAv1Enc's own version string, e.g. "v4.2.0".
String svtAv1Version() => _b.svt_av1_get_version().cast<Utf8>().toDartString();

class Av1EncodeError implements Exception {
  final String reason;
  Av1EncodeError(this.reason);
  @override
  String toString() => 'Av1EncodeError($reason)';
}

/// SvtAv1EncApp's long option names without the dashes — the Mac letter's
/// exact knobs (make_video_letter.sh v3: tune 0, keyint -1, scd, lookahead,
/// tf, qm, variance boost, sharpness 1, hierarchical levels 5, grain off).
const Map<String, String> av1LetterParams = {
  'tune': '0',
  'keyint': '-1',
  'scd': '1',
  'lookahead': '120',
  'enable-tf': '1',
  'film-grain': '0',
  'enable-qm': '1',
  'qm-min': '0',
  'enable-overlays': '0',
  'enable-variance-boost': '1',
  'variance-boost-strength': '2',
  'variance-octile': '6',
  'sharpness': '1',
  'hierarchical-levels': '5',
};

/// Knobs newer than the vendored 4.2.0's guaranteed set, or preset-gated
/// (stronger ARF temporal filtering, loop restoration, CDEF, the deblocking
/// filter): a rejection is skipped, never fatal, so an older library still
/// encodes (Fable 5.1, 2026-09-22; each worth a few percent of bytes).
const Map<String, String> av1LetterOptionalParams = {
  'tf-strength': '3',
  'enable-restoration': '1',
  'enable-cdef': '1',
  'enable-dlf': '1',
};

/// The letter's frame geometry for SIXTY letters (2026-09-22): 216x384
/// portrait at 6 fps — 2.25x the pixels of the 144x256 the owner judged a
/// thumbnail, at the same ~0.10 bits per pixel; the 45-letter plan is
/// 192x336@6. Multiples of 8, and the reader's 2x render (432x768) fits.
// 2026-09-23, measured on the Mac on two real phone clips at the same
// bytes: 288x512@4 beat 216x384@6 by +6 VMAF (20.5 -> 26.9, 44.4 -> 50.2);
// the cost is a slightly jerkier motion. With 100 letters the budget
// roughly doubles for 39 s.
const int videoLetterWidth = 288;
const int videoLetterHeight = 512;
const int videoLetterFps = 4;

/// SVT-AV1 preset for the phone: 5 since the bisect is seeded (two to
/// three passes instead of six, 2026-09-22) — the Mac's preset 2 would
/// take minutes on an A13 for one pass.
const int videoLetterPreset = 5;

/// Tightly packed I420 frames ([width] x [height] x 3/2 B each) ->
/// AV1 temporal units. Synchronous and CPU-bound: call inside
/// [Isolate.run] on a phone.
List<Uint8List> encodeAv1I420(
  Uint8List i420, {
  required int width,
  required int height,
  required int fps,
  required int crf,
  int preset = videoLetterPreset,
}) {
  final frameBytes = width * height * 3 ~/ 2;
  if (i420.isEmpty || i420.length % frameBytes != 0) {
    throw Av1EncodeError(
      '${i420.length} B is not whole ${width}x$height I420 frames',
    );
  }
  final n = i420.length ~/ frameBytes;
  final cfg = calloc<EbSvtAv1EncConfiguration>();
  final handleP = calloc<Pointer<EbComponentType>>();
  var rc = _b.svt_av1_enc_init_handle(handleP, cfg);
  if (rc != EbErrorType.EB_ErrorNone) {
    calloc.free(handleP);
    calloc.free(cfg);
    throw Av1EncodeError('init_handle $rc');
  }
  final h = handleP.value;
  final input = calloc<EbSvtIOFormat>();
  final hdr = calloc<EbBufferHeaderType>();
  final pkt = calloc<Pointer<EbBufferHeaderType>>();
  final plane = calloc<Uint8>(frameBytes);
  final out = <Uint8List>[];
  BytesBuilder? tu;
  var inited = false;
  try {
    cfg.ref
      ..source_width = width
      ..source_height = height
      ..frame_rate_numerator = fps
      ..frame_rate_denominator = 1
      ..encoder_bit_depth = 8
      ..encoder_color_formatAsInt = EbColorFormat.EB_YUV420.value;
    void set(String k, String v) {
      final kk = k.toNativeUtf8();
      final vv = v.toNativeUtf8();
      try {
        if (_b.svt_av1_enc_parse_parameter(cfg, kk.cast(), vv.cast()) !=
            EbErrorType.EB_ErrorNone) {
          throw Av1EncodeError('rejected $k=$v');
        }
      } finally {
        calloc.free(kk);
        calloc.free(vv);
      }
    }

    av1LetterParams.forEach(set);
    av1LetterOptionalParams.forEach((k, v) {
      try {
        set(k, v);
      } on Av1EncodeError {
        // older library: the knob is absent, the letter is not.
      }
    });
    set('preset', '$preset');
    set('crf', '$crf'); // crf => rate control mode 0 + tpl, as the CLI
    if (_b.svt_av1_enc_set_parameter(h, cfg) != EbErrorType.EB_ErrorNone) {
      throw Av1EncodeError('set_parameter');
    }
    if (_b.svt_av1_enc_init(h) != EbErrorType.EB_ErrorNone) {
      throw Av1EncodeError('init');
    }
    inited = true;
    final y = plane;
    final u = plane + width * height;
    final v = u + width * height ~/ 4;
    input.ref
      ..luma = y
      ..cb = u
      ..cr = v
      ..y_stride = width
      ..cb_stride = width ~/ 2
      ..cr_stride = width ~/ 2;
    // One wire unit per temporal delimiter: a packet without HAS_TD
    // continues the previous unit (a hidden ALTREF and its show-existing
    // ride together; dav1d on both ends accepts a unit holding two TUs).
    void drain({required bool flush}) {
      for (;;) {
        rc = _b.svt_av1_enc_get_packet(h, pkt, flush ? 1 : 0);
        if (rc == EbErrorType.EB_NoErrorEmptyQueue) return;
        if (rc != EbErrorType.EB_ErrorNone)
          throw Av1EncodeError('get_packet $rc');
        final p = pkt.value.ref;
        final bytes = Uint8List.fromList(
          p.p_buffer.asTypedList(p.n_filled_len),
        );
        final hasTd = (p.flags & EB_BUFFERFLAG_HAS_TD) != 0;
        final last = (p.flags & EB_BUFFERFLAG_EOS) != 0;
        _b.svt_av1_enc_release_out_buffer(pkt);
        if (hasTd && tu != null) {
          out.add(tu!.takeBytes());
          tu = null;
        }
        (tu ??= BytesBuilder(copy: false)).add(bytes);
        if (last) {
          if (tu != null) {
            out.add(tu!.takeBytes());
            tu = null;
          }
          return;
        }
      }
    }

    for (var i = 0; i < n; i++) {
      plane
          .asTypedList(frameBytes)
          .setAll(
            0,
            Uint8List.sublistView(i420, i * frameBytes, (i + 1) * frameBytes),
          );
      hdr.ref
        ..size = sizeOf<EbBufferHeaderType>()
        ..p_buffer = input.cast()
        ..n_filled_len = frameBytes
        ..n_alloc_len = frameBytes
        ..pts = i
        ..flags = 0
        ..pic_typeAsInt = EbAv1PictureType.EB_AV1_INVALID_PICTURE.value;
      if (_b.svt_av1_enc_send_picture(h, hdr) != EbErrorType.EB_ErrorNone) {
        throw Av1EncodeError('send picture $i');
      }
      drain(flush: false); // the library copied the planes
    }
    hdr.ref
      ..p_buffer = nullptr
      ..n_filled_len = 0
      ..pts = n
      ..flags = EB_BUFFERFLAG_EOS;
    if (_b.svt_av1_enc_send_picture(h, hdr) != EbErrorType.EB_ErrorNone) {
      throw Av1EncodeError('send eos');
    }
    drain(flush: true);
    if (tu != null) out.add(tu!.takeBytes());
    return out;
  } finally {
    if (inited) _b.svt_av1_enc_deinit(h);
    _b.svt_av1_enc_deinit_handle(h);
    calloc.free(plane);
    calloc.free(pkt);
    calloc.free(hdr);
    calloc.free(input);
    calloc.free(handleP);
    calloc.free(cfg);
  }
}

/// The video wire's flags nibble for its audio tail (pack_video_note_v2.py
/// MODES): 5 = Opus 6k CBR, 45 B packets; 6 = Opus SILK VBR at 16 kHz,
/// one length byte per 60 ms packet ([u8 len][packet] — the voice
/// letter's mode-6 packing minus its header). [VideoNote.encode] writes 0
/// (Codec2 700C) and never reads it, so the letter builder stamps it.
const int videoLetterAudioModeOpus = 5;
const int videoLetterAudioModeOpusVbr = 6;

/// The wideband tail's rate: the rung the voice letter proved excellent
/// (row 83314d80, ~11.7 kbit/s measured); ~45 KB per 30 s of normalised
/// speech, about one crf step off the video (Fable 5.1, 2026-09-22).
const int videoLetterAudioBitrate = 12000;

/// Length-prefixed Opus SILK VBR tail over s16le 16 kHz mono [pcm16k].
Uint8List encodeVbrTail(Uint8List pcm16k, int bitrate) {
  final codec = OpusVoice.configured(OpusVoiceConfig.vbr(bitrate));
  final tail = BytesBuilder(copy: false);
  try {
    final s16 = Int16List.sublistView(
      pcm16k,
      0,
      pcm16k.length - pcm16k.length % 2,
    );
    final n = codec.samplesPerFrame;
    for (var i = 0; i + n <= s16.length; i += n) {
      final p = codec.encodeFrame(s16.sublist(i, i + n));
      tail.addByte(p.length); // 1..255, checked by encodeFrame
      tail.add(p);
    }
  } finally {
    codec.dispose();
  }
  return tail.takeBytes();
}

/// Packets in a length-prefixed tail.
int countVbrPackets(Uint8List tail) {
  var n = 0;
  for (var p = 0; p < tail.length; p += 1 + tail[p]) {
    n++;
  }
  return n;
}

/// Thrown when no crf in the bisect brings the letter under the budget.
class VideoLetterTooLong implements Exception {
  final int smallestBytes;
  final int budgetBytes;
  VideoLetterTooLong(this.smallestBytes, this.budgetBytes);
  @override
  String toString() =>
      'VideoLetterTooLong($smallestBytes B at crf 63, budget $budgetBytes)';
}

/// What one build measured, beside the wire.
class VideoLetterBuild {
  const VideoLetterBuild({
    required this.wire,
    required this.crf,
    required this.frames,
    required this.audioPackets,
    required this.passes,
  });
  final Uint8List wire;
  final int crf;
  final int frames;
  final int audioPackets;
  final int passes;
}

/// Encodes the audio tail once (Opus SILK VBR wideband, nibble 6, over
/// [pcm16k], s16le 16 kHz mono) and the video at the LOWEST crf whose
/// whole wire fits [budget]. The search is seeded: AV1 bytes scale about
/// as 2^(-dcrf/6), so after each pass the next crf is predicted from the
/// bytes ratio and clamped inside the still-open bisect range — two or
/// three passes instead of six (Fable 5.1, 2026-09-22). Synchronous;
/// [encodeVideoLetter] runs it in an isolate.
VideoLetterBuild buildVideoLetter({
  required Uint8List i420,
  required Uint8List pcm16k,
  required int width,
  required int height,
  required int fps,
  required int budget,
  int preset = videoLetterPreset,
  int audioBitrate = videoLetterAudioBitrate,
  // The bisect may spend the whole budget (crf 16 fills sixty letters at
  // 216x384@6 where 20 left 58 KB unused). The wall was 22 and refused the
  // owner's first real 39 s hand-held take on 2026-09-23 — the accepted
  // 30 s row sat at crf 20 on a steady clip, so a moving one needs a few
  // steps more. 30 still refused it (a busy 39 s clip needed crf 34,
  // measured on the Mac); 40 lets every real take fit, a calm one still
  // lands near crf 20 because the bisect takes the lowest that fits.
  int crfLow = 16,
  int crfHigh = 40,
}) {
  final audio = encodeVbrTail(pcm16k, audioBitrate);
  final audioPackets = countVbrPackets(audio);
  Uint8List? fit;
  var fitCrf = -1;
  var frames = 0;
  var passes = 0;
  var smallest = 1 << 30;
  var lo = crfLow, hi = crfHigh;
  var crf = math.min(math.max(20, crfLow), crfHigh);
  while (lo <= hi) {
    passes++;
    final units = encodeAv1I420(
      i420,
      width: width,
      height: height,
      fps: fps,
      crf: crf,
      preset: preset,
    );
    final wire = VideoNote(
      fps: fps,
      width: width,
      height: height,
      videoFrames: units,
      audioBits: audio,
    ).encode();
    wire[11] = videoLetterAudioModeOpusVbr;
    if (wire.length < smallest) smallest = wire.length;
    if (wire.length <= budget) {
      fit = wire;
      fitCrf = crf;
      frames = units.length;
      hi = crf - 1;
    } else {
      lo = crf + 1;
    }
    if (lo > hi) break;
    final videoBytes = wire.length - videoNoteHeaderBytes - audio.length;
    final room = budget - videoNoteHeaderBytes - audio.length;
    final guess = videoBytes <= 0 || room <= 0
        ? (lo + hi) ~/ 2
        : crf - (6 * (math.log(room / videoBytes) / math.ln2)).round();
    crf = guess.clamp(lo, hi);
  }
  if (fit == null) throw VideoLetterTooLong(smallest, budget);
  return VideoLetterBuild(
    wire: fit,
    crf: fitCrf,
    frames: frames,
    audioPackets: audioPackets,
    passes: passes,
  );
}

/// One still: RGBA in, an AVIF file out, crf bisected until it fits
/// [budget]. The same encoder the video letter uses (the phone's vendored
/// SVT-AV1), so a photo costs about a quarter fewer bytes than JPEG at
/// equal quality — measured 2026-09-23 on the real phone photo 402504ee:
/// JPEG 113532 B -> ssim 0.9727, AVIF 92638 B -> 0.9759. Keyframe only,
/// 4:2:0, no grain synthesis. Returns null when even crf [crfHigh] is too
/// large, so the caller can drop an edge.
Uint8List? encodeAvifStill(
  Uint8List rgba, {
  required int width,
  required int height,
  required int budget,
  int preset = 4,
  int crfLow = 12,
  int crfHigh = 55,
}) {
  final i420 = rgbaToI420(rgba, width: width, height: height);
  Uint8List? fit;
  var lo = crfLow, hi = crfHigh;
  var crf = (crfLow + crfHigh) ~/ 2;
  while (lo <= hi) {
    // One frame at 1 fps: the wire carries the bitstream, not a cadence.
    final units = encodeAv1I420(
      i420,
      width: width,
      height: height,
      fps: 1,
      crf: crf,
      preset: preset,
    );
    if (units.isEmpty) return null;
    final file = wrapAvif(units.first, width: width, height: height);
    if (file.length <= budget) {
      fit = file;
      hi = crf - 1;
    } else {
      lo = crf + 1;
    }
    if (lo > hi) break;
    crf = (lo + hi) ~/ 2;
  }
  return fit;
}

/// RGBA8888 -> tightly packed I420 (BT.601 limited range, the wire's own
/// assumption; 2x2 box average for the chroma planes).
Uint8List rgbaToI420(
  Uint8List rgba, {
  required int width,
  required int height,
}) {
  final out = Uint8List(width * height * 3 ~/ 2);
  final uAt = width * height;
  final vAt = uAt + width * height ~/ 4;
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final p = (y * width + x) * 4;
      final r = rgba[p], g = rgba[p + 1], b = rgba[p + 2];
      out[y * width + x] = ((66 * r + 129 * g + 25 * b + 128) >> 8) + 16;
    }
  }
  for (var y = 0; y < height ~/ 2; y++) {
    for (var x = 0; x < width ~/ 2; x++) {
      var sr = 0, sg = 0, sb = 0;
      for (var dy = 0; dy < 2; dy++) {
        for (var dx = 0; dx < 2; dx++) {
          final p = ((2 * y + dy) * width + 2 * x + dx) * 4;
          sr += rgba[p];
          sg += rgba[p + 1];
          sb += rgba[p + 2];
        }
      }
      final r = sr ~/ 4, g = sg ~/ 4, b = sb ~/ 4;
      out[uAt + y * (width ~/ 2) + x] =
          ((-38 * r - 74 * g + 112 * b + 128) >> 8) + 128;
      out[vAt + y * (width ~/ 2) + x] =
          ((112 * r - 94 * g - 18 * b + 128) >> 8) + 128;
    }
  }
  return out;
}

/// [buildVideoLetter] on a worker isolate, so the phone's UI and the rig
/// peer's heartbeat keep running through the bisect.
Future<VideoLetterBuild> encodeVideoLetter({
  required Uint8List i420,
  required Uint8List pcm16k,
  required int width,
  required int height,
  required int fps,
  required int budget,
  int preset = videoLetterPreset,
}) => Isolate.run(
  () => buildVideoLetter(
    i420: i420,
    pcm16k: pcm16k,
    width: width,
    height: height,
    fps: fps,
    budget: budget,
    preset: preset,
  ),
);
