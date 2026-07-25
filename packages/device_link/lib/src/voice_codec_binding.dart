/// Seam for the device's downloadable neural voice codec ("quality
/// column"): the model that turns waveform frames into discrete token
/// columns and back. Like the on-device language model, the codec model
/// is fetched per device; until it is present, [available] is false and
/// the survival ladder must skip the token-voice rung.
///
/// This package defines only the binding contract — the real
/// platform implementation (mobile NPU / desktop) plugs in behind it,
/// and `hamseda_codec` compresses the produced columns for the wire.
library;

/// Static description of a voice codec model installed on this device.
class VoiceCodecModelInfo {
  const VoiceCodecModelInfo({
    required this.modelId,
    required this.nRows,
    required this.frameMillis,
    required this.rawBitsPerFrame,
  });

  /// Identity of the downloaded codec model (name + revision).
  final String modelId;

  /// Codebook rows per token column (arity of each column).
  final int nRows;

  /// Duration one token column represents.
  final double frameMillis;

  /// Raw (uncompressed) bits one column costs on the wire.
  final int rawBitsPerFrame;
}

/// Device binding for the neural voice codec used by the token-voice
/// survival rung. All methods are async: real implementations cross a
/// platform channel and may lazily load the model.
abstract interface class VoiceCodecBinding {
  /// Whether the codec model is downloaded and loadable on this device.
  Future<bool> get available;

  /// Info for the installed model; throws [StateError] when unavailable.
  Future<VoiceCodecModelInfo> get modelInfo;

  /// Encodes PCM samples into token columns (each of length `nRows`).
  Future<List<List<int>>> encodeFrames(List<double> samples);

  /// Decodes token columns back into PCM samples.
  Future<List<double>> decodeFrames(List<List<int>> columns);
}

/// In-memory simulation for tests and the reference app: "installs" a
/// model flag and round-trips a deterministic toy tokenization so the
/// ladder and wire layers can be exercised without a real neural codec.
class SimulatedVoiceCodecBinding implements VoiceCodecBinding {
  SimulatedVoiceCodecBinding({bool installed = false})
      : _installed = installed;

  bool _installed;

  /// Simulates the model download completing (or being removed).
  set installed(bool value) => _installed = value;

  static const _info = VoiceCodecModelInfo(
    modelId: 'sim-encodec-1k5-v1',
    nRows: 2,
    frameMillis: 13.3,
    rawBitsPerFrame: 20,
  );

  @override
  Future<bool> get available async => _installed;

  @override
  Future<VoiceCodecModelInfo> get modelInfo async {
    if (!_installed) throw StateError('voice codec model not installed');
    return _info;
  }

  @override
  Future<List<List<int>>> encodeFrames(List<double> samples) async {
    if (!_installed) throw StateError('voice codec model not installed');
    // Deterministic toy quantizer: 160 samples -> one 2-row column.
    final cols = <List<int>>[];
    for (var i = 0; i + 160 <= samples.length; i += 160) {
      var acc0 = 0.0;
      var acc1 = 0.0;
      for (var j = 0; j < 160; j++) {
        final s = samples[i + j];
        acc0 += s.abs();
        acc1 += s * (j.isEven ? 1 : -1);
      }
      cols.add([
        (acc0 * 4).round() % 1024,
        ((acc1.abs() * 8).round() + 512) % 1024,
      ]);
    }
    return cols;
  }

  @override
  Future<List<double>> decodeFrames(List<List<int>> columns) async {
    if (!_installed) throw StateError('voice codec model not installed');
    // Toy reconstruction with the right shape (160 samples per column).
    return [
      for (final col in columns)
        for (var j = 0; j < 160; j++) (col[0] / 1024.0) * (j.isEven ? 1 : -1)
    ];
  }
}
