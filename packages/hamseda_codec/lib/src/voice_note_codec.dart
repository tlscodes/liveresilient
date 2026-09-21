import 'dart:typed_data';

/// Phase 5 peak 3 — voice note wire format (Codec2).
///
/// A 10s voice note travels as bit-packed Codec2 frames under a 4-byte header:
///   [0] ver (high nibble) | mode (low nibble)   mode: 1=700C, 2=1200,
///       3=1600, 4=2400, 5=3200 (Codec2); 12=Opus 6k NB CBR 60 ms (45 B
///       frames, byte-aligned); 6=Opus SILK VBR 60 ms at 16 kHz, each
///       packet behind ONE length byte [u8 len][packet] (TOC inside, so
///       NB or WB rides per packet); 13 and 14 are RESERVED for Lyra v2 3.2k /
///       6k (2026-09-21, not built); 15 is reserved as the extension escape.
///   [1..2] frameCount, little-endian u16
///   [3] flags (reserved, 0)
///   [4..] frames bit-packed CONTIGUOUSLY: 700C frames are 28 bits each and
///         NOT byte aligned — N frames occupy ceil(N*28/8) bytes (padded
///         per-frame 4-byte layout would throw away 12.5% of the wire budget).
/// Encoding/decoding of the frames themselves is Codec2 (native, injected on
/// device via FFI; host measurement uses c2enc/c2dec). This file owns layout,
/// the bit packer, and clean failure on malformed frames.

const int voiceNoteVersion = 1;
const int voiceNoteHeaderBytes = 4;

/// Reserved wire nibbles: a receiver names them in its refusal instead of
/// "unknown mode" so a letter from a newer sender is diagnosable.
const int voiceNoteModeLyra3200Reserved = 13;
const int voiceNoteModeLyra6000Reserved = 14;
const int voiceNoteModeExtensionReserved = 15;

enum VoiceNoteMode {
  c700(1, 28, 8, 40),
  c1200(2, 48, 5, 40),
  c1600(3, 64, 2, 40),
  c2400(4, 48, 1, 20),
  c3200(5, 64, 0, 20),

  /// Opus 6 kbit/s narrowband, hard CBR, 60 ms frames: 45 B each, 750 B/s,
  /// 30 s in six letters. Judged clean on real speech where Codec2 3200
  /// was hissy (2026-09-21). Not a Codec2 mode: codec2Mode is -1.
  opus6k(12, 360, -1, 60),

  /// Opus SILK VBR, 60 ms packets, 16 kHz PCM on both sides. Each packet
  /// rides behind ONE length byte (1..255, TOC inside), so bitsPerFrame is
  /// 0 (variable) and the bandwidth (NB under 9 kbit/s, WB above) is the
  /// packet's own. The default for any take the ten letters carry at
  /// 6 kbit/s or more; the recorder's fit loop owns the bitrate — never
  /// [pick], which cannot size a variable wire ahead. Id 6, the first free
  /// nibble (owner's verdict on mode 12: 70/100; Fable 5.1's final design,
  /// 2026-09-21).
  opusVbr(6, 0, -1, 60, sampleRate: 16000);

  const VoiceNoteMode(
    this.id,
    this.bitsPerFrame,
    this.codec2Mode,
    this.frameMs, {
    this.sampleRate = 8000,
  });

  /// The wire nibble.
  final int id;

  /// Bits per packed frame; 0 for a variable (length-prefixed) mode.
  final int bitsPerFrame;

  /// libcodec2's mode int (codec2.h); -1 for Opus.
  final int codec2Mode;

  /// Frame length in milliseconds: 20 for 3200/2400, 40 for the low
  /// Codec2 modes, 60 for Opus.
  final int frameMs;

  /// PCM rate the frame codec takes and gives: 8000 for Codec2 and
  /// mode 12, 16000 for [opusVbr].
  final int sampleRate;

  /// True for the Opus modes; the frame codec is picked by
  /// voice_frame_codec.dart's voiceFrameCodecFor.
  bool get isOpus => codec2Mode < 0;

  /// Length-prefixed packets instead of fixed bit-packed frames.
  bool get isVariable => bitsPerFrame == 0;

  /// Bytes per second of wire, before the 4 B header; 0 for a variable
  /// mode — measure the wire.
  double get bytesPerSecond => bitsPerFrame / 8 * (1000 / frameMs);

  /// Bits per second the mode's name promises (700C is 700).
  int get bitsPerSecond => (bytesPerSecond * 8).round();

  /// The best FIXED mode whose wire for [length] fits [budgetBytes] (header
  /// included), highest quality first — Opus 6k before any Codec2 mode —
  /// 700C when nothing fits. [opusVbr] is never here: its bitsPerFrame is
  /// 0, so it would "fit" any length at four bytes.
  static VoiceNoteMode pick(Duration length, int budgetBytes) {
    for (final m in const [opus6k, c3200, c2400, c1600, c1200, c700]) {
      final frames = length.inMilliseconds ~/ m.frameMs;
      final bytes = voiceNoteHeaderBytes + (frames * m.bitsPerFrame + 7) ~/ 8;
      if (bytes <= budgetBytes) return m;
    }
    return c700;
  }
}

class MalformedVoiceNote implements Exception {
  final String reason;
  MalformedVoiceNote(this.reason);
  @override
  String toString() => 'MalformedVoiceNote($reason)';
}

/// Packs [frames] (each exactly [mode].bitsPerFrame bits, given as byte lists
/// whose trailing bits beyond bitsPerFrame must be zero) into the contiguous
/// bit stream.
Uint8List packVoiceNote({
  required List<Uint8List> frames,
  required VoiceNoteMode mode,
}) {
  if (frames.length > 0xFFFF) {
    throw MalformedVoiceNote('too many frames: ${frames.length}');
  }
  if (mode.isVariable) return _packVariable(frames, mode);
  final bpf = mode.bitsPerFrame;
  final frameBytes = (bpf + 7) >> 3;
  final totalBits = frames.length * bpf;
  final out = Uint8List(voiceNoteHeaderBytes + ((totalBits + 7) >> 3));
  out[0] = (voiceNoteVersion << 4) | mode.id;
  out[1] = frames.length & 0xFF;
  out[2] = (frames.length >> 8) & 0xFF;
  out[3] = 0;
  var bitPos = 0;
  for (final f in frames) {
    if (f.length != frameBytes) {
      throw MalformedVoiceNote('frame is ${f.length}B, want $frameBytes');
    }
    for (var b = 0; b < bpf; b++) {
      final bit = (f[b >> 3] >> (7 - (b & 7))) & 1;
      if (bit != 0) {
        final p = bitPos + b;
        out[voiceNoteHeaderBytes + (p >> 3)] |= 1 << (7 - (p & 7));
      }
    }
    bitPos += bpf;
  }
  return out;
}

/// [4 B header][u8 len][len bytes] x frameCount. A zero-length packet is
/// not an Opus packet and is refused here, not at the decoder.
Uint8List _packVariable(List<Uint8List> frames, VoiceNoteMode mode) {
  var total = 0;
  for (final f in frames) {
    if (f.isEmpty || f.length > 0xFF) {
      throw MalformedVoiceNote('frame is ${f.length}B, want 1..255');
    }
    total += 1 + f.length;
  }
  final out = Uint8List(voiceNoteHeaderBytes + total);
  out[0] = (voiceNoteVersion << 4) | mode.id;
  out[1] = frames.length & 0xFF;
  out[2] = (frames.length >> 8) & 0xFF;
  out[3] = 0;
  var p = voiceNoteHeaderBytes;
  for (final f in frames) {
    out[p++] = f.length;
    out.setRange(p, p + f.length, f);
    p += f.length;
  }
  return out;
}

/// Every bound is checked before it is read: a truncated wire is a
/// [MalformedVoiceNote] naming the frame, never a RangeError.
List<Uint8List> _unpackVariable(Uint8List wire, int count) {
  final frames = <Uint8List>[];
  var p = voiceNoteHeaderBytes;
  for (var i = 0; i < count; i++) {
    if (p >= wire.length) {
      throw MalformedVoiceNote('frame $i of $count: no length byte at $p');
    }
    final n = wire[p++];
    if (n == 0) throw MalformedVoiceNote('frame $i of $count is empty');
    if (p + n > wire.length) {
      throw MalformedVoiceNote(
        'frame $i needs $n B at $p, wire ends at ${wire.length}',
      );
    }
    frames.add(wire.sublist(p, p + n));
    p += n;
  }
  return frames;
}

/// Unpacks the wire back into per-frame byte lists (trailing bits zeroed
/// for the bit-packed modes; whole packets for the variable mode), ready
/// to feed the frame decoder.
/// The mode a wire names, or [MalformedVoiceNote].
VoiceNoteMode voiceNoteModeOf(Uint8List wire) {
  if (wire.length < voiceNoteHeaderBytes) {
    throw MalformedVoiceNote('shorter than header: ${wire.length}');
  }
  return _modeOfNibble(wire[0] & 0x0F);
}

VoiceNoteMode _modeOfNibble(int nibble) {
  if (nibble == voiceNoteModeLyra3200Reserved ||
      nibble == voiceNoteModeLyra6000Reserved) {
    throw MalformedVoiceNote(
      'mode $nibble is reserved for Lyra v2 (not built)',
    );
  }
  if (nibble == voiceNoteModeExtensionReserved) {
    throw MalformedVoiceNote('mode 15 is the reserved extension escape');
  }
  return VoiceNoteMode.values.firstWhere(
    (m) => m.id == nibble,
    orElse: () => throw MalformedVoiceNote('unknown mode $nibble'),
  );
}

List<Uint8List> unpackVoiceNote(Uint8List wire) {
  if (wire.length < voiceNoteHeaderBytes) {
    throw MalformedVoiceNote('shorter than header: ${wire.length}');
  }
  if (wire[0] >> 4 != voiceNoteVersion) {
    throw MalformedVoiceNote('unknown version ${wire[0] >> 4}');
  }
  final mode = _modeOfNibble(wire[0] & 0x0F);
  final count = wire[1] | (wire[2] << 8);
  if (mode.isVariable) return _unpackVariable(wire, count);
  final bpf = mode.bitsPerFrame;
  final needBits = count * bpf;
  final haveBits = (wire.length - voiceNoteHeaderBytes) * 8;
  if (haveBits < needBits) {
    throw MalformedVoiceNote('need $needBits bits, have $haveBits');
  }
  final frameBytes = (bpf + 7) >> 3;
  final frames = <Uint8List>[];
  for (var i = 0; i < count; i++) {
    final f = Uint8List(frameBytes);
    for (var b = 0; b < bpf; b++) {
      final p = i * bpf + b;
      final bit = (wire[voiceNoteHeaderBytes + (p >> 3)] >> (7 - (p & 7))) & 1;
      if (bit != 0) f[b >> 3] |= 1 << (7 - (b & 7));
    }
    frames.add(f);
  }
  return frames;
}
