/// The place-network micro-learner: online training, forecasting, and
/// corrupt-safe persistence.
library;

import 'package:connection_orchestrator/connection_orchestrator.dart';
import 'package:test/test.dart';

ConnectivityExperience exp(
  String place,
  String network,
  double quality, {
  double slope = 0,
  int at = 0,
}) => ConnectivityExperience(
  placeTag: place,
  networkName: network,
  quality: quality,
  slope: slope,
  atMs: at,
);

void main() {
  test('learns which network is best at each place independently', () {
    final learner = MicroLearner();
    for (var i = 0; i < 10; i++) {
      learner.observe(exp('home', 'HomeNet', 0.9));
      learner.observe(exp('home', 'CellA', 0.3));
      learner.observe(exp('office', 'CellA', 0.85));
    }

    final home = learner.forecastFor('home');
    expect(home.first.networkName, 'HomeNet');
    expect(home.first.expectedQuality, greaterThan(0.8));
    expect(learner.expectedQuality('home', 'CellA'), lessThan(0.4));
    expect(
      learner.expectedQuality('office', 'CellA'),
      greaterThan(0.7),
      reason: 'the same network can be great elsewhere',
    );
    expect(learner.forecastFor('nowhere'), isEmpty);
  });

  test('adapts online when a place changes character', () {
    final learner = MicroLearner(alpha: 0.4);
    for (var i = 0; i < 10; i++) {
      learner.observe(exp('cafe', 'CafeWifi', 0.9));
    }
    for (var i = 0; i < 6; i++) {
      learner.observe(exp('cafe', 'CafeWifi', 0.1));
    }
    expect(learner.expectedQuality('cafe', 'CafeWifi'), lessThan(0.3));
  });

  test('round-trips through JSON with the whole map intact', () {
    final learner = MicroLearner();
    learner.observe(exp('home', 'HomeNet', 0.9, slope: -0.01));
    learner.observe(exp('home', 'CellA', 0.2));

    final restored = MicroLearner.fromJson(learner.toJson());

    expect(
      restored.expectedQuality('home', 'HomeNet'),
      learner.expectedQuality('home', 'HomeNet'),
    );
    expect(restored.forecastFor('home').first.networkName, 'HomeNet');
  });

  test('corrupt persistence degrades to a fresh brain, never a crash', () {
    final restored = MicroLearner.fromJson({
      'places': {
        'home': {
          'good': {'q': 0.8, 's': 0.0, 'w': 4},
          'bad-quality': {'q': 7, 's': 0, 'w': 1},
          'not-a-map': 'garbage',
        },
        'broken-place': 'garbage',
      },
    });
    expect(restored.expectedQuality('home', 'good'), 0.8);
    expect(restored.expectedQuality('home', 'bad-quality'), 0.5);
    expect(MicroLearner.fromJson('total garbage').forecastFor('x'), isEmpty);
  });

  test('experience records validate their own JSON', () {
    final e = exp('home', 'net', 0.7, slope: -0.02, at: 123);
    final back = ConnectivityExperience.fromJson(e.toJson());
    expect(back!.placeTag, 'home');
    expect(back.quality, 0.7);
    expect(ConnectivityExperience.fromJson({'place': 'x'}), isNull);
    expect(ConnectivityExperience.fromJson('junk'), isNull);
  });
}
