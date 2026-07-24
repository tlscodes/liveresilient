/// The on-device micro-learner: a tiny continuously-trained model over
/// (place, network) pairs.
///
/// Where [LaneExperience] learns per-lane delivery success and
/// [TrendSentinel] watches one lane's live trajectory, this learner
/// builds the device's long-term map of the physical world: "at this
/// place, this network usually behaves like this". Each observation
/// updates a per-(place, network) exponentially-weighted quality estimate
/// and keeps the latest fitted slope, so the app can pre-rank networks
/// the moment the user arrives somewhere — before sending a single byte.
/// Persistence is corrupt-safe: a damaged file restores to a fresh brain.
library;

/// One recorded observation.
class ConnectivityExperience {
  const ConnectivityExperience({
    required this.placeTag,
    required this.networkName,
    required this.quality,
    required this.slope,
    required this.atMs,
  });

  /// Coarse location label (never a precise position).
  final String placeTag;

  /// The network's user-visible identity at that place.
  final String networkName;

  /// Observed quality score 0..1 at the time.
  final double quality;

  /// Fitted health slope at the time (score units per second).
  final double slope;

  final int atMs;

  Map<String, Object?> toJson() => {
    'place': placeTag,
    'network': networkName,
    'quality': quality,
    'slope': slope,
    'at': atMs,
  };

  static ConnectivityExperience? fromJson(Object? json) {
    if (json is! Map) return null;
    final place = json['place'];
    final network = json['network'];
    final quality = json['quality'];
    final slope = json['slope'];
    final at = json['at'];
    if (place is! String || network is! String) return null;
    if (quality is! num || quality < 0 || quality > 1) return null;
    if (slope is! num || at is! num) return null;
    return ConnectivityExperience(
      placeTag: place,
      networkName: network,
      quality: quality.toDouble(),
      slope: slope.toDouble(),
      atMs: at.toInt(),
    );
  }
}

class _PairModel {
  double quality = 0.5;
  double slope = 0;
  double weight = 0;

  void train(double q, double s, {required double alpha}) {
    quality = (1 - alpha) * quality + alpha * q;
    slope = (1 - alpha) * slope + alpha * s;
    weight += 1;
  }
}

/// A ranked prediction for one network at a place.
class NetworkForecast {
  const NetworkForecast({
    required this.networkName,
    required this.expectedQuality,
    required this.evidence,
  });

  final String networkName;
  final double expectedQuality;

  /// Number of observations behind the estimate.
  final double evidence;
}

/// Tiny online-trained model, updated on every observation.
class MicroLearner {
  MicroLearner({this.alpha = 0.2})
    : assert(alpha > 0 && alpha <= 1, 'alpha must be in (0, 1]');

  /// Learning rate of the exponentially-weighted update.
  final double alpha;

  final Map<String, Map<String, _PairModel>> _byPlace = {};

  /// Trains on one experience — a few multiplications, safe to call on
  /// every signal sample.
  void observe(ConnectivityExperience e) {
    _byPlace
        .putIfAbsent(e.placeTag, () => {})
        .putIfAbsent(e.networkName, _PairModel.new)
        .train(e.quality, e.slope, alpha: alpha);
  }

  /// Predicted quality for a specific pair (0.5 when unknown).
  double expectedQuality(String placeTag, String networkName) =>
      _byPlace[placeTag]?[networkName]?.quality ?? 0.5;

  /// All known networks at a place, best expected quality first — the
  /// pre-ranking the fabric can seed lane costs with on arrival.
  List<NetworkForecast> forecastFor(String placeTag) {
    final models = _byPlace[placeTag];
    if (models == null) return const [];
    final list = [
      for (final e in models.entries)
        NetworkForecast(
          networkName: e.key,
          expectedQuality: e.value.quality,
          evidence: e.value.weight,
        ),
    ]..sort((a, b) => b.expectedQuality.compareTo(a.expectedQuality));
    return list;
  }

  /// Serializes the whole model for on-disk persistence.
  Map<String, Object?> toJson() => {
    'places': {
      for (final p in _byPlace.entries)
        p.key: {
          for (final n in p.value.entries)
            n.key: {
              'q': n.value.quality,
              's': n.value.slope,
              'w': n.value.weight,
            },
        },
    },
  };

  /// Restores a persisted model; malformed entries are dropped silently
  /// so a corrupt file yields a fresh (never crashing) learner.
  factory MicroLearner.fromJson(Object? json, {double alpha = 0.2}) {
    final learner = MicroLearner(alpha: alpha);
    if (json is! Map) return learner;
    final places = json['places'];
    if (places is! Map) return learner;
    for (final p in places.entries) {
      if (p.key is! String || p.value is! Map) continue;
      for (final n in (p.value as Map).entries) {
        final v = n.value;
        if (n.key is! String || v is! Map) continue;
        final q = v['q'];
        final s = v['s'];
        final w = v['w'];
        if (q is! num || q < 0 || q > 1) continue;
        if (s is! num || w is! num || w < 0) continue;
        learner._byPlace.putIfAbsent(p.key as String, () => {})[n.key
            as String] = _PairModel()
          ..quality = q.toDouble()
          ..slope = s.toDouble()
          ..weight = w.toDouble();
      }
    }
    return learner;
  }
}
