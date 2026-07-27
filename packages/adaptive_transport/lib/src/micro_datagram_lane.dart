import 'dart:math';
import 'dart:typed_data';

/// Pads a datagram up to a whole number of MTU blocks, per RFC 3711 style
/// padding (SRTP), so its length on the wire is a multiple of the block
/// size instead of a function of the payload.
///
/// Wire format: `payload · random pad bytes · u16 big-endian padLength`.
/// The pad-length trailer is TWO bytes so full-MTU block sizes (1400-1500,
/// up to [maxBlockSize]) can never truncate the recorded length mod 256 —
/// the single-byte format silently corrupted any frame whose padLength
/// exceeded 255.
///
/// To blunt traffic-analysis quantization (every wire length landing on the
/// minimal block multiple), 0..[_maxJitterBlocks] whole extra blocks of
/// random padding are added, so the block count itself varies per frame.
class MicroDatagramLane {
  /// [random] defaults to [Random.secure]. Injecting a non-secure RNG is
  /// only permitted for deterministic tests via [allowInsecureRandom] —
  /// padding content is a security surface.
  MicroDatagramLane({Random? random, bool allowInsecureRandom = false})
      : _random = random ?? Random.secure() {
    if (random != null && !allowInsecureRandom) {
      throw ArgumentError(
        'Injected RNG requires allowInsecureRandom: true (test-only); '
        'padding entropy must default to Random.secure()',
      );
    }
  }

  final Random _random;

  static const int _maxRandomPad = 32;
  static const int _maxJitterBlocks = 3;

  /// Two-byte big-endian pad-length trailer.
  static const int trailerBytes = 2;

  /// Largest blockSize for which the worst-case padLength
  /// (_maxRandomPad + blockSize - 1 + _maxJitterBlocks * blockSize)
  /// provably fits the u16 trailer.
  static const int maxBlockSize =
      (0xFFFF - _maxRandomPad + 1) ~/ (1 + _maxJitterBlocks);

  Uint8List encodeWithPadding(Uint8List payload, {int blockSize = 16}) {
    if (blockSize < 1 || blockSize > maxBlockSize) {
      throw ArgumentError.value(
        blockSize,
        'blockSize',
        'must be in [1, $maxBlockSize] so padLength fits the u16 trailer',
      );
    }
    final int basePad = _random.nextInt(_maxRandomPad) + 1;
    final int totalLen = payload.length + basePad + trailerBytes;
    int padLength = basePad;
    final int remainder = totalLen % blockSize;
    if (remainder != 0) {
      padLength += blockSize - remainder;
    }
    // Block-count jitter: whole extra blocks keep alignment but decouple
    // the wire block count from the payload length.
    padLength += _random.nextInt(_maxJitterBlocks + 1) * blockSize;
    assert(padLength <= 0xFFFF);

    final padded = Uint8List(payload.length + padLength + trailerBytes);
    padded.setRange(0, payload.length, payload);
    for (int i = 0; i < padLength; i++) {
      padded[payload.length + i] = _random.nextInt(256);
    }
    padded[padded.length - 2] = (padLength >> 8) & 0xFF;
    padded[padded.length - 1] = padLength & 0xFF;
    return padded;
  }

  Uint8List decodeAndStripPadding(Uint8List paddedFrame) {
    if (paddedFrame.length < trailerBytes) {
      throw FormatException(
        'Frame shorter than the $trailerBytes-byte pad trailer: '
        '${paddedFrame.length}',
      );
    }
    final int padLength = (paddedFrame[paddedFrame.length - 2] << 8) |
        paddedFrame[paddedFrame.length - 1];
    final int originalLength = paddedFrame.length - trailerBytes - padLength;
    if (originalLength < 0) {
      throw FormatException('Invalid padding boundary length: $padLength');
    }
    return Uint8List.sublistView(paddedFrame, 0, originalLength);
  }
}
