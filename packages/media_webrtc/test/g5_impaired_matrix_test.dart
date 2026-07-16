/// G5 impaired-network matrix — SIMULATION ONLY.
///
/// These tests exercise the full stats -> sampler -> policy -> sender-
/// parameter path of [WebRtcMediaEngine] under a deterministic impairment
/// model (see `support/impaired_network.dart`), entirely under `fake_async`
/// (zero wall-clock, zero real timers).
///
/// Scope note: the blueprint's G5 exit gate (setup success >= 99% / >= 95%,
/// P95 setup time) is a REAL-DEVICE lab measurement and is out of scope
/// here. What this matrix proves is the *policy and stability behavior*
/// the gate depends on: stepwise audio-first degradation, no crash or
/// deadlock at extreme loss, hysteresis-bounded recovery, and accurate
/// counter/decision reporting.
library;

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:media_webrtc/media_webrtc.dart';
import 'package:test/test.dart';

import 'support/impaired_network.dart';

/// One recorded profile change plus the (1-based) index of the smoothed
/// sample that triggered it — used to verify slow-up hysteresis spacing.
class _RecordedDecision {
  final MediaPolicyDecision decision;
  final int sampleIndex;
  _RecordedDecision(this.decision, this.sampleIndex);
}

class _ScenarioResult {
  final MediaProfile finalProfile;
  final List<_RecordedDecision> decisions;
  final List<RtcStatsSample> samples;
  final SimulatedPeerConnectionPort port;

  _ScenarioResult({
    required this.finalProfile,
    required this.decisions,
    required this.samples,
    required this.port,
  });

  List<MediaProfile> get profilePath => [
    if (decisions.isNotEmpty) decisions.first.decision.previous,
    for (final d in decisions) d.decision.next,
  ];
}

const _statsInterval = Duration(seconds: 2);

/// Runs [ticks] sampling intervals of the engine against the simulator,
/// with per-tick impairment chosen by [paramsForTick]. Fully deterministic
/// for a fixed [seed]; the fake clock is the only clock (fake_async installs
/// its clock into package:clock inside the zone, which the sampler uses).
_ScenarioResult _runScenario({
  required int seed,
  required int ticks,
  required ImpairmentParams Function(int tick) paramsForTick,
  MediaProfile initialProfile = MediaProfile.high,
}) {
  late _ScenarioResult result;

  fakeAsync((async) {
    final simulator = ImpairedNetworkSimulator(
      seed: seed,
      params: paramsForTick(0),
    );
    final port = SimulatedPeerConnectionPort(simulator);
    final engine = WebRtcMediaEngine(
      port: port,
      policy: AdaptiveMediaPolicy(initialProfile: initialProfile),
      statsInterval: _statsInterval,
    );

    final decisions = <_RecordedDecision>[];
    final samples = <RtcStatsSample>[];
    engine.events.listen((event) {
      switch (event) {
        case MediaStatsUpdated(:final sample):
          samples.add(sample);
        case MediaProfileChanged(:final decision):
          decisions.add(_RecordedDecision(decision, samples.length));
        case MediaConnectionChanged():
          break;
      }
    });

    // Connecting starts the sampler; every subsequent poll is driven purely
    // by elapsing the fake clock one interval at a time (never concurrently,
    // which also respects the sampler's single-flight guard).
    port.emitStatus(PeerConnectionStatus.connected);
    async.flushMicrotasks();

    for (var tick = 0; tick < ticks; tick++) {
      simulator.params = paramsForTick(tick);
      async.elapse(_statsInterval);
    }

    // Closing stops the sampler. Afterwards the fake event loop must be
    // completely drained: no pending timer and no queued microtask, i.e.
    // every tick was processed with zero backlog and nothing hung.
    port.emitStatus(PeerConnectionStatus.closed);
    async.flushMicrotasks();
    expect(
      async.periodicTimerCount,
      0,
      reason: 'sampler timer must be cancelled after close',
    );
    expect(
      async.nonPeriodicTimerCount,
      0,
      reason: 'no stray timers may remain',
    );
    expect(async.microtaskCount, 0, reason: 'no unprocessed backlog');

    expect(
      simulator.ticksGenerated,
      ticks,
      reason: 'every fake-clock tick must produce exactly one stats poll',
    );

    result = _ScenarioResult(
      finalProfile: engine.currentProfile,
      decisions: decisions,
      samples: samples,
      port: port,
    );

    // Not awaited: StreamSubscription.cancel() does not settle through
    // fake_async's queue (documented harness quirk in
    // call_core/test/call_controller_test.dart); the engine's own state is
    // torn down synchronously before the first await.
    unawaited(engine.dispose());
    unawaited(port.disposeStreams());
    async.flushMicrotasks();
  });

  return result;
}

void main() {
  group('G5 matrix (simulated): normal network', () {
    // 0.5% loss / 15ms jitter / 50ms RTT.
    test('policy holds high and never leaves video profiles', () {
      final result = _runScenario(
        seed: 11,
        ticks: 20,
        paramsForTick: (_) =>
            const ImpairmentParams(lossRate: 0.005, jitterMs: 15, rttMs: 50),
      );

      expect(result.finalProfile, MediaProfile.high);
      expect(
        result.decisions,
        isEmpty,
        reason: 'a clean network must cause zero profile changes',
      );
      // First poll is the delta baseline: N ticks -> N-1 samples.
      expect(result.samples, hasLength(19));
      for (final sample in result.samples) {
        expect(sample.packetLossFraction, lessThan(0.05));
        expect(sample.rttMs, lessThan(600));
      }
      expect(
        result.port.appliedVideoParameters,
        isEmpty,
        reason: 'no decision -> no sender-parameter churn',
      );
    });
  });

  group('G5 matrix (simulated): 10% loss / 80ms jitter / 300ms RTT', () {
    test(
      'degrades stepwise through every rung down to audioOnly, no crash',
      () {
        final result = _runScenario(
          seed: 22,
          ticks: 16,
          paramsForTick: (_) =>
              const ImpairmentParams(lossRate: 0.10, jitterMs: 80, rttMs: 300),
        );

        expect(result.finalProfile, MediaProfile.audioOnly);

        // Audio-first: 10% loss is "bad" but below the severe threshold, so
        // the ladder must be walked one rung at a time, never skipped.
        final path = result.profilePath;
        expect(path, [
          MediaProfile.high,
          MediaProfile.medium,
          MediaProfile.low,
          MediaProfile.minimal,
          MediaProfile.audioOnly,
        ]);
        for (final recorded in result.decisions) {
          expect(
            recorded.decision.next.index - recorded.decision.previous.index,
            1,
            reason:
                'non-severe loss must downgrade single-step: '
                '${recorded.decision}',
          );
        }

        // Audio survives: the final applied parameters disable video while
        // keeping an audio bitrate floor.
        final lastVideo = result.port.appliedVideoParameters.last;
        expect(lastVideo.enabled, isFalse);
        expect(result.port.appliedAudioMaxBitrates.last, greaterThan(0));
      },
    );
  });

  group('G5 matrix (simulated): 35% loss, then recovery', () {
    test('completes every tick with zero backlog, lands audioOnly, and '
        'climbs back to high under slow-up hysteresis', () {
      const impairedTicks = 10;
      const recoveryTicks = 60;
      var recoveryStartSample = 0;

      final result = _runScenario(
        seed: 33,
        ticks: impairedTicks + recoveryTicks,
        paramsForTick: (tick) => tick < impairedTicks
            ? const ImpairmentParams(lossRate: 0.35, jitterMs: 120, rttMs: 500)
            : const ImpairmentParams(
                lossRate: 0.01,
                jitterMs: 10,
                rttMs: 40,
                availableOutgoingBitrateBps: 5000000,
              ),
      );

      // Accurate reporting: one smoothed sample per tick after the delta
      // baseline, none dropped, none duplicated.
      expect(result.samples, hasLength(impairedTicks + recoveryTicks - 1));

      // Severe loss (>= 20%) must take the two-step emergency path down.
      final downgrades = result.decisions
          .where((r) => r.decision.next.index > r.decision.previous.index)
          .toList();
      expect(
        [for (final r in downgrades) r.decision.next],
        [MediaProfile.low, MediaProfile.audioOnly],
        reason: 'severe loss: high -2-> low -2-> audioOnly',
      );
      expect(
        downgrades.last.sampleIndex,
        lessThanOrEqualTo(impairedTicks),
        reason: 'audioOnly must be reached during the impaired phase',
      );

      // Recovery: the ladder is climbed one rung at a time back to high.
      final upgrades = result.decisions
          .where((r) => r.decision.next.index < r.decision.previous.index)
          .toList();
      expect(
        [for (final r in upgrades) r.decision.next],
        [
          MediaProfile.minimal,
          MediaProfile.low,
          MediaProfile.medium,
          MediaProfile.high,
        ],
      );
      expect(result.finalProfile, MediaProfile.high);

      // Slow-up hysteresis: each upgrade needs >= 8 consecutive clean
      // samples, so consecutive upgrades are >= 8 samples apart and the
      // first one happens no sooner than 8 samples into recovery.
      recoveryStartSample = impairedTicks - 1;
      expect(
        upgrades.first.sampleIndex - recoveryStartSample,
        greaterThanOrEqualTo(8),
      );
      for (var i = 1; i < upgrades.length; i++) {
        expect(
          upgrades[i].sampleIndex - upgrades[i - 1].sampleIndex,
          greaterThanOrEqualTo(8),
          reason:
              'upgrade $i arrived faster than the clean-sample '
              'hold-down allows',
        );
      }
    });
  });

  group('G5 matrix (simulated): oscillating boundary (8% / 2% bursts)', () {
    test('hysteresis bounds transitions: monotonic ratchet, no flapping', () {
      const ticks = 48;
      final result = _runScenario(
        seed: 44,
        ticks: ticks,
        // Three-tick bursts alternating just above (8%) and just below (2%)
        // the 5% downgrade threshold — the classic flapping provocation.
        paramsForTick: (tick) => (tick ~/ 3).isEven
            ? const ImpairmentParams(lossRate: 0.08, jitterMs: 40, rttMs: 150)
            : const ImpairmentParams(lossRate: 0.02, jitterMs: 20, rttMs: 80),
      );

      // Bounded transition count: a naive threshold policy would flap on
      // every burst edge (~16 changes over 48 ticks); hysteresis must cap
      // the total at the ladder depth.
      expect(result.decisions.length, lessThanOrEqualTo(4));

      // And every change must point the same way (downward ratchet) — an
      // upgrade needs 8 consecutive clean samples, which 3-tick clean
      // bursts can never supply. No up/down oscillation at all.
      for (final recorded in result.decisions) {
        expect(
          recorded.decision.next.index,
          greaterThan(recorded.decision.previous.index),
          reason:
              'oscillating input must never produce an upgrade: '
              '${recorded.decision}',
        );
      }
      expect(
        result.finalProfile,
        MediaProfile.audioOnly,
        reason: 'repeated bad bursts ratchet down to audioOnly and hold',
      );
    });
  });
}
