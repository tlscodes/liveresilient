/// Widget tests for the reference app's UI state wiring.
///
/// The full real chain runs except the platform edge: a REAL
/// [CallController] + REAL [WebRtcCallMediaSession] drive the UI, with the
/// `flutter_webrtc` [PeerConnectionPort] replaced by [MockPeerConnectionPort]
/// and the WSS transport/signaling replaced by in-memory fakes (host
/// `flutter test` cannot load native plugins; the loopback E2E over the real
/// plugin is the next wave's integration test).
library;

import 'dart:async';

import 'package:call_core/call_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_webrtc/media_webrtc.dart' as mw;
import 'package:reference_app/main.dart';
import 'package:reference_app/src/call_session.dart';
import 'package:reference_app/src/webrtc_media_session.dart';

const _fakeSdp =
    'v=0\r\n'
    'o=- 1 1 IN IP4 127.0.0.1\r\n'
    's=-\r\n'
    't=0 0\r\n'
    'm=audio 9 UDP/TLS/RTP/SAVPF 111\r\n';

/// Mocked platform port: answers the negotiation calls with canned SDP and
/// flips to connected the moment its side of the offer/answer handshake
/// completes (initiator: remote answer applied; receiver: local answer
/// applied) — mirroring a real ICE agent, never a timer.
class MockPeerConnectionPort implements mw.PeerConnectionPort {
  final _status = StreamController<mw.PeerConnectionStatus>.broadcast();
  final _candidates = StreamController<mw.IceCandidate>.broadcast();

  final localDescriptions = <mw.SdpDescription>[];
  final remoteDescriptions = <mw.SdpDescription>[];
  bool closed = false;

  @override
  Stream<mw.PeerConnectionStatus> get connectionStatus => _status.stream;

  @override
  Stream<mw.IceCandidate> get localCandidates => _candidates.stream;

  @override
  Future<mw.SdpDescription> createOffer({required bool iceRestart}) async {
    return mw.SdpDescription(type: 'offer', sdp: _fakeSdp);
  }

  @override
  Future<mw.SdpDescription> createAnswer() async {
    return mw.SdpDescription(type: 'answer', sdp: _fakeSdp);
  }

  @override
  Future<void> setLocalDescription(mw.SdpDescription description) async {
    localDescriptions.add(description);
    if (description.type == 'answer') _connect();
  }

  @override
  Future<void> setRemoteDescription(mw.SdpDescription description) async {
    remoteDescriptions.add(description);
    if (description.type == 'answer') _connect();
  }

  @override
  Future<void> addRemoteCandidate(mw.IceCandidate candidate) async {}

  @override
  Future<void> setVideoSenderParameters(
    mw.VideoSenderParameters parameters,
  ) async {}

  @override
  Future<void> setAudioMaxBitrate(int bitrateBps) async {}

  @override
  Future<mw.RawRtcCounters?> readStatsCounters() async => null;

  @override
  Future<void> close() async {
    closed = true;
    await _status.close();
    await _candidates.close();
  }

  void _connect() {
    if (!_status.isClosed) {
      _status.add(mw.PeerConnectionStatus.connected);
    }
  }
}

class FakeTransport implements CallTransport {
  final _events = StreamController<TransportEvent>.broadcast();

  @override
  Stream<TransportEvent> get events => _events.stream;

  @override
  Future<void> connect() async {
    _events.add(const TransportEvent(TransportStatus.connected));
  }

  @override
  Future<void> disconnect() async {}
}

/// In-memory far end: answers an outgoing offer, and (for the receiver
/// role) sends an incoming offer as soon as signaling starts.
class FakeSignaling implements CallSignaling {
  final _events = StreamController<SignalingEvent>.broadcast();
  final sentCommands = <SignalingCommand>[];

  @override
  Stream<SignalingEvent> get events => _events.stream;

  @override
  Future<void> start({required String callId, required CallRole role}) async {
    if (role == CallRole.receiver) {
      _emitLater(
        RemoteDescriptionEvent(
          SessionDescription(type: SessionDescriptionType.offer, sdp: _fakeSdp),
        ),
      );
    }
  }

  @override
  Future<void> send(SignalingCommand command) async {
    sentCommands.add(command);
    if (command is SendDescriptionCommand &&
        command.description.type == SessionDescriptionType.offer) {
      _emitLater(
        RemoteDescriptionEvent(
          SessionDescription(
            type: SessionDescriptionType.answer,
            sdp: _fakeSdp,
          ),
        ),
      );
    }
  }

  @override
  Future<void> stop() async {}

  void _emitLater(SignalingEvent event) {
    scheduleMicrotask(() {
      if (!_events.isClosed) _events.add(event);
    });
  }
}

CallSessionBuilder _fakeSessionBuilder(MockPeerConnectionPort port) {
  return ({
    required Uri endpoint,
    required String callId,
    required CallRole role,
  }) {
    final controller = CallController(
      callId: callId,
      role: role,
      transport: FakeTransport(),
      signaling: FakeSignaling(),
      media: WebRtcCallMediaSession(() async => port),
      reconnectPolicy: ExponentialBackoffReconnectPolicy(
        maxAttempts: 1,
        baseDelay: const Duration(milliseconds: 10),
        maxDelay: const Duration(milliseconds: 10),
        maxElapsed: const Duration(milliseconds: 100),
      ),
    );
    return CallSessionHandle(
      controller: controller,
      dispose: () => controller.dispose(),
    );
  };
}

/// Pumps until [finder] matches, interleaving a real-event-loop hop
/// (`tester.runAsync`) with each fake-async pump.
///
/// The hop is load-bearing: cancelling a broadcast StreamSubscription
/// returns the SDK's root-zone `_nullFuture`, whose continuation is
/// scheduled on the REAL event loop — invisible to FakeAsync pumps. The
/// call stack awaits such cancels during teardown (e.g. `CallController`'s
/// `_cancelSubscriptions`), so a pump-only loop deadlocks at `ending`
/// while timers and `close()` futures still fire (verified empirically).
Future<void> _pumpUntilFound(
  WidgetTester tester,
  Finder finder, {
  int maxPumps = 50,
}) async {
  for (var i = 0; i < maxPumps; i++) {
    if (finder.evaluate().isNotEmpty) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump(const Duration(milliseconds: 20));
  }
  final status = tester
      .widgetList<Text>(find.textContaining('Status:'))
      .map((text) => text.data)
      .join(', ');
  expect(finder, findsOneWidget, reason: 'actual status line: $status');
}

void main() {
  testWidgets('renders idle state with call fields', (tester) async {
    await tester.pumpWidget(
      ReferenceApp(
        sessionBuilder: _fakeSessionBuilder(MockPeerConnectionPort()),
      ),
    );

    expect(find.text('Status: idle'), findsOneWidget);
    expect(find.text('wss://localhost:8443'), findsOneWidget);
    expect(find.text('call-1'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Hang up'), findsOneWidget);
  });

  testWidgets(
    'invite drives status through connected and hangup ends the call',
    (tester) async {
      final port = MockPeerConnectionPort();
      await tester.pumpWidget(
        ReferenceApp(sessionBuilder: _fakeSessionBuilder(port)),
      );

      await tester.tap(find.text('Invite'));
      await _pumpUntilFound(tester, find.text('Status: connected'));

      // The mocked port saw the real negotiation flow.
      expect(port.localDescriptions.map((d) => d.type), ['offer']);
      expect(port.remoteDescriptions.map((d) => d.type), ['answer']);

      await tester.tap(find.text('Hang up'));
      await _pumpUntilFound(tester, find.text('Status: ended (localHangup)'));

      // Session teardown closed the mocked platform port.
      expect(port.closed, isTrue);
    },
  );

  testWidgets('accept answers an incoming offer and reaches connected', (
    tester,
  ) async {
    final port = MockPeerConnectionPort();
    await tester.pumpWidget(
      ReferenceApp(sessionBuilder: _fakeSessionBuilder(port)),
    );

    await tester.tap(find.text('Accept'));
    await _pumpUntilFound(tester, find.text('Status: connected'));

    expect(port.remoteDescriptions.map((d) => d.type), ['offer']);
    expect(port.localDescriptions.map((d) => d.type), ['answer']);

    // End the call so no live session (and none of its timers) outlives
    // the widget tree.
    await tester.tap(find.text('Hang up'));
    await _pumpUntilFound(tester, find.text('Status: ended (localHangup)'));
  });
}
