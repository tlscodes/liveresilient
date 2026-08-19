import 'dart:typed_data';

/// Phase 5 peak 3 — voice note wire format (Codec2).
///
/// A 10s voice note travels as bit-packed Codec2 frames under a 4-byte header:
///   [0] ver (high nibble) | mode (low nibble)   mode: 1=700C, 2=1200
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

enum VoiceNoteMode {
  c700(1, 28),
  c1200(2, 48);

  const VoiceNoteMode(this.id, this.bitsPerFrame);
  final int id;
  final int bitsPerFrame;
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

/// Unpacks the wire back into per-frame byte lists (trailing bits zeroed),
/// ready to feed the Codec2 decoder.
List<Uint8List> unpackVoiceNote(Uint8List wire) {
  if (wire.length < voiceNoteHeaderBytes) {
    throw MalformedVoiceNote('shorter than header: ${wire.length}');
  }
  if (wire[0] >> 4 != voiceNoteVersion) {
    throw MalformedVoiceNote('unknown version ${wire[0] >> 4}');
  }
  final mode = VoiceNoteMode.values.firstWhere(
    (m) => m.id == (wire[0] & 0x0F),
    orElse: () => throw MalformedVoiceNote('unknown mode ${wire[0] & 0x0F}'),
  );
  final count = wire[1] | (wire[2] << 8);
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
