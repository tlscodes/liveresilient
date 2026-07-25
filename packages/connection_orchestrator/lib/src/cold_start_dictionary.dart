/// Cold-start dictionary for the token-voice lane.
///
/// All measured bitrates so far are for a WARM contact (per-contact
/// dictionary persisted from earlier calls). A first-ever call used to
/// start from a completely empty codec state, making the opening seconds
/// the most expensive of the whole call. This manager fixes that with a
/// pre-agreed static base dictionary: a fixed table both ends already
/// ship with (like a config file — nothing is downloaded or exchanged),
/// built deterministically from a seeded generic token stream so encoder
/// and decoder derive byte-identical state with zero setup traffic.
/// The very first frame of a cold call can therefore be encoded and
/// decoded immediately — no round trip, no negotiation (0-RTT).
///
/// Once a verified per-contact warm state becomes available (loaded from
/// the contact store, or carried in a dynamic-state payload whose
/// trailing CRC-8 checks out), the call transitions from the static base
/// to the warm state at an explicit block boundary. Blocks are coded
/// independently against a frozen snapshot, so the switch is clean: both
/// ends flip at the same block seq and every block before and after
/// decodes bit-exact.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:hamseda_codec/hamseda_codec.dart';

/// CRC-8 (poly 0x07), same polynomial as the micro-datagram lane.
int crc8(Uint8List bytes, [int? end]) {
  final n = end ?? bytes.length;
  var crc = 0;
  for (var i = 0; i < n; i++) {
    crc ^= bytes[i];
    for (var b = 0; b < 8; b++) {
      crc = (crc & 0x80) != 0 ? ((crc << 1) ^ 0x07) & 0xFF : (crc << 1) & 0xFF;
    }
  }
  return crc;
}

/// Which dictionary the codec pipeline is currently coding against.
enum DictionaryPhase {
  /// Pre-agreed static base dictionary — active from the first frame.
  staticBase,

  /// Per-contact warm state adopted after CRC verification.
  dynamicWarm,
}

/// Owns the codec state across a call's cold start: static base first,
/// per-contact warm state after a verified handover.
class ColdStartDictionaryManager {
  ColdStartDictionaryManager() : _state = baseState();

  HamsedaState _state;
  DictionaryPhase _phase = DictionaryPhase.staticBase;

  /// Current phase, for diagnostics and tests.
  DictionaryPhase get phase => _phase;

  /// Frozen snapshot to code the next block against (blocks are always
  /// coded against a clone so a lost block never breaks the next one).
  HamsedaState snapshot() => _state.clone();

  /// The number of rows in an EnCodec token column at the bitrate the
  /// token-voice lane uses.
  static const int rows = 2;

  /// Frames of generic seeded speech-like tokens the base dictionary is
  /// trained on. Both ends run the identical derivation, so the result
  /// is byte-identical without exchanging anything.
  static const int _baseTrainingFrames = 1500;

  static Uint8List? _cachedBaseDict;

  /// The pre-compiled static base dictionary: serialized codec state
  /// with a trailing CRC-8. Derived deterministically on first use and
  /// cached; every process on every device computes the same bytes.
  static Uint8List get staticBaseDict => _cachedBaseDict ??= _buildBaseDict();

  static Uint8List _buildBaseDict() {
    final state = HamsedaState(rows);
    encodeColumns(baseTrainingStream(_baseTrainingFrames), state);
    final body = utf8.encode(jsonEncode(state.toJson()));
    final out = Uint8List(body.length + 1);
    out.setAll(0, body);
    out[body.length] = crc8(out, body.length);
    return out;
  }

  /// The generic speech-shaped token stream the base dictionary is
  /// trained on (small stable alphabet, strong successor structure,
  /// silence runs). Public so callers and tests can know exactly which
  /// columns the base pre-learns: the base dictionary only helps a cold
  /// call to the extent the caller's real tokens OVERLAP this alphabet
  /// (measured: a base trained on fully disjoint tokens makes the
  /// opening seconds slightly worse, not better). In production this
  /// stream must be derived from real EnCodec token statistics over
  /// many speakers, not from synthetic data.
  static List<List<int>> baseTrainingStream(int frames) {
    var x = 4242;
    int next(int mod) {
      // xorshift32 — fixed here so the derivation can never drift
      // between platforms or dart versions (unlike Random's algorithm,
      // this is pinned by this file).
      x ^= (x << 13) & 0xFFFFFFFF;
      x ^= x >> 17;
      x ^= (x << 5) & 0xFFFFFFFF;
      return x % mod;
    }

    const alphabetSize = 48;
    final alphabet = [
      for (var i = 0; i < alphabetSize; i++) [next(1024), next(1024)]
    ];
    final successors = [
      for (var i = 0; i < alphabetSize; i++)
        [next(alphabetSize), next(alphabetSize), next(alphabetSize)]
    ];
    final silence = [next(1024), next(1024)];
    final out = <List<int>>[];
    var cur = 0;
    while (out.length < frames) {
      if (next(100) < 25) {
        final run = 5 + next(25);
        for (var i = 0; i < run && out.length < frames; i++) {
          out.add(List.of(silence));
        }
        continue;
      }
      cur = successors[cur][next(3)];
      out.add(List.of(alphabet[cur]));
    }
    return out;
  }

  /// Deserializes [staticBaseDict] into a live codec state. Both call
  /// ends start from this — it IS the shared pre-agreed table.
  static HamsedaState baseState() {
    final dict = staticBaseDict;
    final body = utf8.decode(Uint8List.sublistView(dict, 0, dict.length - 1));
    return HamsedaState.fromJson(jsonDecode(body) as Map<String, dynamic>);
  }

  /// Verifies and adopts a per-contact warm state: [payload] is
  /// serialized state JSON with a trailing CRC-8 (the same format as
  /// [staticBaseDict]). Returns true and switches to
  /// [DictionaryPhase.dynamicWarm] when the CRC and parse succeed;
  /// returns false and stays on the current state otherwise. Call this
  /// only at a block boundary agreed by both ends (e.g. "warm from
  /// block N"), so encoder and decoder flip in step.
  bool adoptWarmState(Uint8List payload) {
    if (payload.length < 2) return false;
    final end = payload.length - 1;
    if (payload[end] != crc8(payload, end)) return false;
    final HamsedaState warm;
    try {
      warm = HamsedaState.fromJson(jsonDecode(
              utf8.decode(Uint8List.sublistView(payload, 0, end)))
          as Map<String, dynamic>);
    } on FormatException {
      return false;
    }
    _state = warm;
    _phase = DictionaryPhase.dynamicWarm;
    return true;
  }

  /// Serializes a warm state into the CRC-8-trailed payload format
  /// [adoptWarmState] accepts.
  static Uint8List packWarmState(HamsedaState state) {
    final body = utf8.encode(jsonEncode(state.toJson()));
    final out = Uint8List(body.length + 1);
    out.setAll(0, body);
    out[body.length] = crc8(out, body.length);
    return out;
  }
}
