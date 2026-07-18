/// Shared event-driven test synchronization for the relay test suites.
///
/// Both relay_server_test.dart and abuse_controls_test.dart originally paced
/// themselves with fixed 100ms settle sleeps, which was this package's flake
/// source: under heavy parallel machine load a TLS round-trip can exceed any
/// fixed delay, so assertions ran before frames arrived (first observed
/// 2026-07-18 as a `__seed__` frame leaking into an assertion list). The
/// helpers here wait on the actual event instead of a clock guess.
library;

import 'dart:async';

import 'package:signaling_server/signaling_server.dart';
import 'package:test/test.dart';

/// Upper bound on any single wait. Generous on purpose: it only fires on a
/// genuine hang, never paces a passing run (waits complete the moment the
/// expected condition holds).
const frameWaitTimeout = Duration(seconds: 10);

/// Collects frames from one socket and lets a test await an exact count.
class FrameCollector {
  final List<String> frames = <String>[];
  final List<(int, Completer<void>)> _waiters = <(int, Completer<void>)>[];

  void add(String frame) {
    frames.add(frame);
    _waiters.removeWhere((waiter) {
      if (frames.length >= waiter.$1) {
        waiter.$2.complete();
        return true;
      }
      return false;
    });
  }

  /// Completes when at least [count] frames have been collected.
  Future<void> waitForCount(int count, String what) {
    if (frames.length >= count) return Future<void>.value();
    final completer = Completer<void>();
    _waiters.add((count, completer));
    return completer.future.timeout(
      frameWaitTimeout,
      onTimeout: () => fail(
        'Timed out waiting for $count frame(s) ($what); '
        'received so far: $frames',
      ),
    );
  }
}

/// Polls the in-process [server] until [activeRooms] matches. Used where the
/// awaited event is server-internal state (room creation/teardown) with no
/// client-visible frame to wait on.
Future<void> waitForActiveRooms(
  SignalingRelayServer server,
  int activeRooms,
) async {
  final deadline = DateTime.now().add(frameWaitTimeout);
  while (server.activeRooms != activeRooms) {
    if (DateTime.now().isAfter(deadline)) {
      fail(
        'Timed out waiting for activeRooms == $activeRooms; '
        'still at ${server.activeRooms}',
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}
