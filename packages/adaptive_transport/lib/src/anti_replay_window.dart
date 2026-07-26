/// Sliding anti-replay window: a highest-seen counter plus a fixed-size bitmap
/// of recently seen sequence numbers (the RFC 4303 section 3.4.3 algorithm,
/// also used by DTLS and IPsec).
///
/// Compared to a spent-nonce set this is O(1) memory (one int + one bitmap
/// word list) and O(1) per check, regardless of traffic rate.
class AntiReplayWindow {
  AntiReplayWindow({this.windowSize = 1024})
      : assert(windowSize >= 64 && windowSize % 64 == 0,
            'windowSize must be a positive multiple of 64'),
        _bitmap = List<int>.filled(windowSize ~/ 64, 0);

  /// Width of the acceptance window in sequence numbers.
  final int windowSize;

  final List<int> _bitmap;
  int _highest = -1;

  int _accepted = 0;
  int _rejectedReplay = 0;
  int _rejectedStale = 0;

  int get highestAccepted => _highest;
  int get acceptedCount => _accepted;
  int get rejectedReplayCount => _rejectedReplay;
  int get rejectedStaleCount => _rejectedStale;

  bool _bitAt(int seq) {
    final offset = seq % windowSize;
    return (_bitmap[offset >> 6] >> (offset & 63)) & 1 == 1;
  }

  void _setBit(int seq) {
    final offset = seq % windowSize;
    _bitmap[offset >> 6] |= 1 << (offset & 63);
  }

  void _clearBit(int seq) {
    final offset = seq % windowSize;
    _bitmap[offset >> 6] &= ~(1 << (offset & 63));
  }

  /// Accepts [sequence] exactly once.
  ///
  /// Returns false (and counts why) when the number was already seen or has
  /// fallen behind the window's left edge.
  bool accept(int sequence) {
    if (sequence < 0) {
      _rejectedStale++;
      return false;
    }
    if (sequence > _highest) {
      // Advance: clear every slot the window slides across.
      final int slide = sequence - _highest;
      if (slide >= windowSize) {
        for (var i = 0; i < _bitmap.length; i++) {
          _bitmap[i] = 0;
        }
      } else {
        for (var s = _highest + 1; s <= sequence; s++) {
          _clearBit(s);
        }
      }
      _highest = sequence;
      _setBit(sequence);
      _accepted++;
      return true;
    }
    if (sequence <= _highest - windowSize) {
      _rejectedStale++;
      return false;
    }
    if (_bitAt(sequence)) {
      _rejectedReplay++;
      return false;
    }
    _setBit(sequence);
    _accepted++;
    return true;
  }
}
