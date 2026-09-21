/// One frame codec behind the voice-note wire: Codec2 (modes 1..5) or Opus
/// 6k (mode 12). The recorder, the CLI tools and the phone-side player all
/// go through [voiceFrameCodecFor] so a mode is added in one place.
library;

import 'dart:typed_data';

import 'codec2_ffi.dart';
import 'opus_ffi.dart';
import 'voice_note_codec.dart';

abstract class VoiceFrameCodec {
  /// PCM rate the codec takes and gives: 8000 for Codec2 and mode 12,
  /// 16000 for the wideband Opus mode, 48000 for the hybrid mode.
  int get sampleRate;

  /// s16 samples per frame at [sampleRate].
  int get samplesPerFrame;

  /// Bits per packed frame on the wire.
  int get bitsPerFrame;

  Uint8List encodeFrame(Int16List speech);

  Int16List decodeFrame(Uint8List frame);

  void dispose();
}

/// The codec a wire mode names. [decoderComplexity] only matters to Opus
/// (OSCE enhancement at 6 or 7, effective on wideband packets); Codec2
/// ignores it. [opusBitrate] only matters to the VBR mode — the recorder's
/// fit loop owns it; a decoder can leave the default.
VoiceFrameCodec voiceFrameCodecFor(
  VoiceNoteMode mode, {
  int decoderComplexity = 0,
  int opusBitrate = 10000,
}) {
  if (mode == VoiceNoteMode.opusHybrid) {
    return OpusVoice.configured(
      OpusVoiceConfig.hybrid(opusBitrate),
      decoderComplexity: decoderComplexity,
    );
  }
  if (mode == VoiceNoteMode.opusVbr) {
    return OpusVoice.configured(
      OpusVoiceConfig.vbr(opusBitrate),
      decoderComplexity: decoderComplexity,
    );
  }
  if (mode.isOpus) return OpusVoice(decoderComplexity: decoderComplexity);
  return Codec2(mode.codec2Mode);
}
