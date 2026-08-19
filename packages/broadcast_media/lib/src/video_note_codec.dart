import 'dart:typed_data';

/// Phase 5 peak 4 — video note wire format (raw AV1 + Codec2, no container).
///
/// MP4/MKV/WebM spend kilobytes on metadata; a video note's whole budget is
/// 15KB, so the wire is a raw stream under a 12-byte header (appendix B + E):
///   [0..1]  magic 0x56 0x31 ('V1')
///   [2]     fps
///   [3..4]  width, little-endian u16
///   [5..6]  height, little-endian u16
///   [7..10] audioOffset, little-endian u32 (absolute byte offset)
///   [11]    flags (reserved 0)
/// video section: per frame, 3B little-endian length + AV1 OBU frame bytes
/// audio section: audioOffset..end, bit-packed Codec2 700C
/// De-packaging here is NOT decoding: AV1 frames need dav1d/libgav1 and the
/// decode gate records that honestly.

const int videoNoteHeaderBytes = 12;
const int videoNoteMagic0 = 0x56;
const int videoNoteMagic1 = 0x31;

class MalformedVideoNote implements Exception {
  final String reason;
  MalformedVideoNote(this.reason);
  @override
  String toString() => 'MalformedVideoNote($reason)';
}

final class VideoNote {
  VideoNote({
    required this.fps,
    required this.width,
    required this.height,
    required this.videoFrames,
    required this.audioBits,
  });

  final int fps;
  final int width;
  final int height;
  final List<Uint8List> videoFrames;
  final Uint8List audioBits;

  Uint8List encode() {
    var videoLen = 0;
    for (final f in videoFrames) {
      if (f.length > 0xFFFFFF) {
        throw MalformedVideoNote('frame over 3-byte length: ${f.length}');
      }
      videoLen += 3 + f.length;
    }
    final audioOffset = videoNoteHeaderBytes + videoLen;
    final out = Uint8List(audioOffset + audioBits.length);
    out[0] = videoNoteMagic0;
    out[1] = videoNoteMagic1;
    out[2] = fps;
    out[3] = width & 0xFF;
    out[4] = width >> 8;
    out[5] = height & 0xFF;
    out[6] = height >> 8;
    out[7] = audioOffset & 0xFF;
    out[8] = (audioOffset >> 8) & 0xFF;
    out[9] = (audioOffset >> 16) & 0xFF;
    out[10] = (audioOffset >> 24) & 0xFF;
    out[11] = 0;
    var i = videoNoteHeaderBytes;
    for (final f in videoFrames) {
      out[i] = f.length & 0xFF;
      out[i + 1] = (f.length >> 8) & 0xFF;
      out[i + 2] = (f.length >> 16) & 0xFF;
      out.setRange(i + 3, i + 3 + f.length, f);
      i += 3 + f.length;
    }
    out.setRange(audioOffset, out.length, audioBits);
    return out;
  }

  static VideoNote decode(Uint8List wire) {
    if (wire.length < videoNoteHeaderBytes) {
      throw MalformedVideoNote('shorter than header: ${wire.length}');
    }
    if (wire[0] != videoNoteMagic0 || wire[1] != videoNoteMagic1) {
      throw MalformedVideoNote('bad magic');
    }
    final audioOffset =
        wire[7] | (wire[8] << 8) | (wire[9] << 16) | (wire[10] << 24);
    if (audioOffset < videoNoteHeaderBytes || audioOffset > wire.length) {
      throw MalformedVideoNote('audioOffset $audioOffset out of range');
    }
    final frames = <Uint8List>[];
    var i = videoNoteHeaderBytes;
    while (i < audioOffset) {
      if (i + 3 > audioOffset) {
        throw MalformedVideoNote('truncated frame length at $i');
      }
      final n = wire[i] | (wire[i + 1] << 8) | (wire[i + 2] << 16);
      if (i + 3 + n > audioOffset) {
        throw MalformedVideoNote('frame overruns video section at $i');
      }
      frames.add(Uint8List.sublistView(wire, i + 3, i + 3 + n));
      i += 3 + n;
    }
    return VideoNote(
      fps: wire[2],
      width: wire[3] | (wire[4] << 8),
      height: wire[5] | (wire[6] << 8),
      videoFrames: frames,
      audioBits: Uint8List.sublistView(wire, audioOffset),
    );
  }
}
