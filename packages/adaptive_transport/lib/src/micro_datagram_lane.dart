import 'dart:math';
import 'dart:typed_data';

/// Pads a datagram up to a whole number of MTU blocks, per RFC 3711 style
/// padding (SRTP), so its length on the wire is a multiple of the block
/// size instead of a function of the payload. One trailing byte records
/// the pad length so the original payload can be restored bit-exact.
class MicroDatagramLane {
  MicroDatagramLane({Random? random}) : _random = random ?? Random.secure();

  final Random _random;

  static const int _maxRandomPad = 32;

  Uint8List encodeWithPadding(Uint8List payload, {int blockSize = 16}) {
    if (blockSize < 1) {
      throw ArgumentError.value(blockSize, 'blockSize', 'must be >= 1');
    }
    final int basePad = _random.nextInt(_maxRandomPad) + 1;
    int totalLen = payload.length + basePad + 1;
    int padLength = basePad;
    final int remainder = totalLen % blockSize;
    if (remainder != 0) {
      padLength += blockSize - remainder;
    }

    final padded = Uint8List(payload.length + padLength + 1);
    padded.setRange(0, payload.length, payload);
    for (int i = 0; i < padLength; i++) {
      padded[payload.length + i] = _random.nextInt(256);
    }
    padded[padded.length - 1] = padLength;
    return padded;
  }

  Uint8List decodeAndStripPadding(Uint8List paddedFrame) {
    if (paddedFrame.isEmpty) {
      throw const FormatException('Empty frame received');
    }
    final int padLength = paddedFrame[paddedFrame.length - 1];
    final int originalLength = paddedFrame.length - 1 - padLength;
    if (padLength >= paddedFrame.length || originalLength < 0) {
      throw FormatException('Invalid padding boundary length: $padLength');
    }
    return Uint8List.sublistView(paddedFrame, 0, originalLength);
  }
}
