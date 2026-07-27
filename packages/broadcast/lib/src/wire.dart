/// Fixed-width big-endian wire helpers.
///
/// Every field in this package has a fixed width, so there is no varint
/// and no length negotiation: a descriptor's size is a pure function of
/// its flags. That is what lets a reader reject a truncated or padded
/// descriptor by length alone, before any signature work.
library;

import 'dart:typed_data';

/// Writes big-endian fields into a growing buffer.
class WireWriter {
  final BytesBuilder _out = BytesBuilder(copy: false);

  /// Bytes written so far.
  int get length => _out.length;

  void u8(int value) {
    _range(value, 0xFF, 'u8');
    _out.addByte(value);
  }

  void u16(int value) {
    _range(value, 0xFFFF, 'u16');
    _out.add([(value >> 8) & 0xFF, value & 0xFF]);
  }

  void u32(int value) {
    _range(value, 0xFFFFFFFF, 'u32');
    _out.add([
      (value >> 24) & 0xFF,
      (value >> 16) & 0xFF,
      (value >> 8) & 0xFF,
      value & 0xFF,
    ]);
  }

  /// A five-byte unsigned field. Wide enough for seconds since the epoch
  /// until well past any horizon this code will see, and three bytes
  /// smaller than a u64 — which matters when the whole descriptor is
  /// budgeted in bytes.
  void u40(int value) {
    _range(value, 0xFFFFFFFFFF, 'u40');
    _out.add([
      (value >> 32) & 0xFF,
      (value >> 24) & 0xFF,
      (value >> 16) & 0xFF,
      (value >> 8) & 0xFF,
      value & 0xFF,
    ]);
  }

  void bytes(Uint8List value) => _out.add(value);

  /// The bytes written so far, as a fresh list.
  Uint8List take() => _out.toBytes();

  static void _range(int value, int max, String field) {
    if (value < 0 || value > max) {
      throw ArgumentError.value(value, field, 'out of range for $field');
    }
  }
}

/// Reads big-endian fields, refusing to run past the end of the buffer.
class WireReader {
  WireReader(this._bytes);

  final Uint8List _bytes;
  int _offset = 0;

  /// Bytes not yet consumed.
  int get remaining => _bytes.length - _offset;

  int u8() {
    _need(1);
    return _bytes[_offset++];
  }

  int u16() {
    _need(2);
    final v = (_bytes[_offset] << 8) | _bytes[_offset + 1];
    _offset += 2;
    return v;
  }

  int u32() {
    _need(4);
    final v =
        (_bytes[_offset] << 24) |
        (_bytes[_offset + 1] << 16) |
        (_bytes[_offset + 2] << 8) |
        _bytes[_offset + 3];
    _offset += 4;
    return v;
  }

  int u40() {
    _need(5);
    final v =
        (_bytes[_offset] * 0x100000000) |
        (_bytes[_offset + 1] << 24) |
        (_bytes[_offset + 2] << 16) |
        (_bytes[_offset + 3] << 8) |
        _bytes[_offset + 4];
    _offset += 5;
    return v;
  }

  Uint8List bytes(int count) {
    _need(count);
    final out = Uint8List.fromList(_bytes.sublist(_offset, _offset + count));
    _offset += count;
    return out;
  }

  void _need(int count) {
    if (count < 0 || remaining < count) {
      throw const FormatException('truncated: not enough bytes remaining');
    }
  }
}
