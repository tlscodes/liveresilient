
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:integration_test/integration_test.dart';
import 'package:media_webrtc_flutter/media_webrtc_flutter.dart'
    show FlutterWebRtcPeerConnectionPort;

/// Ticket 3 gate 3f — ON THE DEVICE.
///
/// The unit test for this gate proves what the configuration ASKS FOR. It
/// cannot prove what the ICE agent underneath actually gathers, and its own
/// header says so. This file closes that gap by running on real hardware,
/// letting the platform's ICE agent gather for real, and reading the
/// candidate lines it produces.
///
/// A candidate line's fifth token is its type: `host` is the device's own
/// address, `srflx` is the address a reflector saw, `relay` is an address
/// belonging to a relay. Under a relay-only policy no `host` candidate may
/// appear, because a host candidate IS the local address being offered to
/// the peer.
///
/// HARNESS NOTE (2026-08-16). This file drives `flutter_webrtc` directly,
/// with the exact config map `FlutterWebRtcPeerConnectionPort` hands to
/// `createPeerConnection` — `buildPeerConnectionConfig` is a pure function
/// kept public for asserting that mapping, and `create()` passes its output
/// verbatim as the sole argument. It does NOT go through
/// `FlutterWebRtcPeerConnectionPort.create`, because that path captures
/// the microphone via `getUserMedia`, and on a freshly installed build the
/// iOS permission prompt blocks that call until a human answers it — the
/// previous revision of this file hung BOTH tests for their full 2-minute
/// timeouts exactly there. What the ICE agent needs in order to gather is
/// an m-line, and a receive-only audio transceiver provides one with no
/// capture and no prompt. Collection ends at gathering-complete, with a
/// timer only as a backstop, so the relay case's absence claim is made at
/// end-of-gathering, not at an arbitrary cutoff. What is proven here: the
/// underlying stack's candidate policy on this hardware under this repo's
/// exact configuration. What is NOT proven here: the port's own capture
/// path — the loopback test exercises the port against a real call.
///
/// Run:
///   flutter test integration_test/host_candidate_device_test.dart -d DEVICE_ID
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  /// `candidate:<foundation> <component> <proto> <priority> <ip> <port> typ <type> ...`
  String typeOf(String line) {
    final parts = line.split(' ');
    final i = parts.indexOf('typ');
    return (i >= 0 && i + 1 < parts.length) ? parts[i + 1] : 'unparsed';
  }

  String addressOf(String line) {
    final parts = line.split(' ');
    return parts.length > 4 ? parts[4] : '?';
  }

  Future<({List<String> lines, bool complete})> gather(
    String policy, {
    Duration backstop = const Duration(seconds: 8),
  }) async {
    final pc = await rtc.createPeerConnection(
      FlutterWebRtcPeerConnectionPort.buildPeerConnectionConfig(
        iceServers: const [],
        iceTransportPolicy: policy,
      ),
    );
    final seen = <String>[];
    final gatheringDone = Completer<void>();
    pc.onIceCandidate = (candidate) {
      final line = candidate.candidate;
      if (line != null && line.isNotEmpty) {
        seen.add(line);
      }
    };
    // On native platforms flutter_webrtc signals end-of-candidates through
    // the gathering state, not through an empty candidate line — completion
    // must come from here, never from the sentinel.
    pc.onIceGatheringState = (state) {
      if (state == rtc.RTCIceGatheringState.RTCIceGatheringStateComplete &&
          !gatheringDone.isCompleted) {
        gatheringDone.complete();
      }
    };
    // A peer connection with no m-line has nothing to gather candidates
    // FOR: the offer carries no media section and the ICE agent never
    // starts. The first run of this file made that mistake and reported
    // zero candidates under BOTH policies — at which point the relay-only
    // assertion passed while proving nothing. The baseline test below is
    // what caught it. A receive-only transceiver is the smallest thing
    // that gives the agent work without touching the microphone.
    await pc.addTransceiver(
      kind: rtc.RTCRtpMediaType.RTCRtpMediaTypeAudio,
      init: rtc.RTCRtpTransceiverInit(
        direction: rtc.TransceiverDirection.RecvOnly,
      ),
    );
    // Gathering starts at setLocalDescription, not at createOffer.
    await pc.setLocalDescription(await pc.createOffer());
    // Complete-or-timeout: an absence claim is only as strong as "zero
    // candidates AT gathering-complete"; the backstop timer alone would be
    // "zero candidates in an arbitrary window", which is weaker.
    await gatheringDone.future
        .timeout(backstop, onTimeout: () {});
    final complete = gatheringDone.isCompleted;
    // Detach callbacks BEFORE close: platform-channel events can arrive
    // late, and a late append after the assertions read the list would be
    // a mystery flake.
    pc.onIceCandidate = null;
    pc.onIceGatheringState = null;
    await pc.close();
    await pc.dispose();
    return (lines: seen, complete: complete);
  }

  void report(String policy, ({List<String> lines, bool complete}) got) {
    final byType = <String, int>{};
    for (final line in got.lines) {
      byType.update(typeOf(line), (n) => n + 1, ifAbsent: () => 1);
    }
    // Printed so the run produces an objective record, not just a pass mark.
    // ignore: avoid_print
    print('[3f/device] policy=$policy candidates=${got.lines.length} '
        'gatheringComplete=${got.complete} $byType');
    for (final line in got.lines) {
      // ignore: avoid_print
      print('[3f/device]   typ=${typeOf(line)} addr=${addressOf(line)}');
    }
  }

  group('gate 3f on the device', () {
    testWidgets(
      "3f  policy 'all' DOES offer the device's own address — the baseline that "
      'makes the relay-only result meaningful',
      (tester) async {
        final got = await gather('all');
        report('all', got);
        final hosts = got.lines.where((line) => typeOf(line) == 'host');
        expect(
          hosts,
          isNotEmpty,
          reason: 'if no host candidate appears even under "all", this device '
              'gathered nothing and the relay-only result below would be '
              'vacuously true — which is exactly the false green this test '
              'exists to prevent',
        );
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );

    testWidgets(
      "3f  policy 'relay' offers NO host candidate: the local address does not "
      'leave the device',
      (tester) async {
        final got = await gather('relay');
        report('relay', got);
        final leaked = got.lines
            .where((line) => typeOf(line) == 'host')
            .map(addressOf)
            .toList();
        expect(
          leaked,
          isEmpty,
          reason: 'these host addresses were gathered under a relay-only '
              'policy and would have been offered to the peer: $leaked',
        );
        expect(
          got.lines.where((line) => typeOf(line) == 'srflx'),
          isEmpty,
          reason: 'a server-reflexive candidate is still an address of this '
              'device as a reflector saw it; relay-only must not gather one',
        );
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  });
}
