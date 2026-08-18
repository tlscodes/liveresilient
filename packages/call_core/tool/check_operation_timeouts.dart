// Proves the per-class operation-timeout invariant for every T2 profile.
//
// Mirrors the harness policy in
// apps/reference_app/integration_test/support/e2e_support.dart:
//   class A = max(15s, operationBudget(roundTrips: 5, detectionFloor: 8s))
//   class B = max(20s, operationBudget(roundTrips: 8))
//   class C = 15s fixed (engine-local, network-independent)
// and the profile conditions in tools/t2/h2_run.sh `budget_conditions`.
//
// Invariant, per profile:
//   A: 1*rtt <= tA, tA >= 15s floor, tA <= max(attemptCost + detection, 15s)
//   B: 8*rtt <= tB, tB >= 20s floor, tB <= max(attemptCost, 20s)
//   C: identical on every profile and == 15s (network independence)
//   A also covers a bare 5-round-trip channel establishment (why connect
//     transport / start signaling may share the class-A knob), and no class
//     bound exceeds the profile's whole recovery window (maxElapsed).
//
// Run: cd packages/call_core && dart run tool/check_operation_timeouts.dart

import 'dart:io';

import 'package:call_core/call_core.dart';

const legacyOperation = Duration(seconds: 15);
const legacyConnection = Duration(seconds: 20);
// e2eSignalingConfig.livenessTimeout in e2e_support.dart.
const liveness = Duration(seconds: 8);
// TCP + TLS + WS re-establishment + the resent frame's ack.
const sendRoundTrips = 5;
const classANominalRoundTrips = 1;

final profiles = <String, NetworkConditions>{
  'clean': const NetworkConditions(rtt: Duration(milliseconds: 4), loss: 0),
  'normal': const NetworkConditions(rtt: Duration(milliseconds: 80), loss: 0),
  'latency':
      const NetworkConditions(rtt: Duration(milliseconds: 1800), loss: 0),
  'bandwidth': const NetworkConditions(
    rtt: Duration(milliseconds: 4),
    loss: 0,
    bandwidthBps: 32000,
  ),
  'narrow': const NetworkConditions(
    rtt: Duration(milliseconds: 4),
    loss: 0,
    bandwidthBps: 16000,
  ),
  'loss10':
      const NetworkConditions(rtt: Duration(milliseconds: 4), loss: 0.10),
  'loss60':
      const NetworkConditions(rtt: Duration(milliseconds: 4), loss: 0.60),
  'extreme': const NetworkConditions(
    rtt: Duration(milliseconds: 2000),
    loss: 0.15,
    bandwidthBps: 16000,
  ),
};

Duration maxOf(Duration a, Duration b) => a >= b ? a : b;

String fmt(Duration d) =>
    '${(d.inMilliseconds / 1000).toStringAsFixed(1)}s'.padRight(9);

void main() {
  var failures = 0;
  void check(String profile, String what, bool ok) {
    if (!ok) {
      failures++;
      stderr.writeln('FAIL $profile: $what');
    }
  }

  Duration? engineSeen;
  stdout.writeln('profile    attempt   tA        tB        tC');
  for (final entry in profiles.entries) {
    final name = entry.key;
    final c = entry.value;
    final b = AdaptiveConnectionBudget.fromConditions(c);
    final tA = maxOf(
      legacyOperation,
      b.operationBudget(
        roundTrips: sendRoundTrips,
        detectionFloor: liveness,
      ),
    );
    final tB = maxOf(
      legacyConnection,
      b.operationBudget(
        roundTrips: AdaptiveConnectionBudget.handshakeRoundTrips,
      ),
    );
    const tC = legacyOperation;
    stdout.writeln(
      '${name.padRight(10)} ${fmt(b.attemptCost)} ${fmt(tA)} '
      '${fmt(tB)} ${fmt(tC)}',
    );

    // Class A: nominal r = 1.
    check(name, 'A lower: 1*rtt <= tA', c.rtt * classANominalRoundTrips <= tA);
    check(name, 'A floor: tA >= legacy 15s', tA >= legacyOperation);
    check(
      name,
      'A upper: tA <= max(attemptCost + detection, floor)',
      tA <= maxOf(b.attemptCost + liveness, legacyOperation),
    );
    check(
      name,
      'A covers 5-RT channel establishment without liveness',
      b.operationBudget(roundTrips: sendRoundTrips) <= tA,
    );

    // Class B: r = 8 (full ICE + DTLS + first-media handshake).
    check(
      name,
      'B lower: 8*rtt <= tB',
      c.rtt * AdaptiveConnectionBudget.handshakeRoundTrips <= tB,
    );
    check(name, 'B floor: tB >= legacy 20s', tB >= legacyConnection);
    check(
      name,
      'B upper: tB <= max(attemptCost, floor)',
      tB <= maxOf(b.attemptCost, legacyConnection),
    );

    // Class C: engine-local, identical everywhere.
    engineSeen ??= tC;
    check(name, 'C network-independence', tC == engineSeen);
    check(name, 'C fixed 15s', tC == const Duration(seconds: 15));

    // No single class bound may swallow the whole recovery window.
    check(name, 'tA <= maxElapsed', tA <= b.maxElapsed);
    check(name, 'tB <= maxElapsed', tB <= b.maxElapsed);
  }

  if (failures > 0) {
    stderr.writeln('$failures invariant violation(s)');
    exit(1);
  }
  stdout.writeln('OK: invariant holds for all ${profiles.length} profiles');
}
