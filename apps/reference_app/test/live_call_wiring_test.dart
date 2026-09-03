/// The call tab is driven by a REAL session, and the gauge says where its
/// numbers come from.
///
/// These are the tests the wiring exists for: without them the next person
/// cannot tell whether the gauge is honest. A fake session — a genuine
/// [CallController] over hand-driven ports, so every phase transition is the
/// controller's own — stands in for the WebRTC stack that `flutter test`
/// cannot build. Nothing here touches a network.
library;

import 'dart:async';

import 'package:call_core/call_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reference_app/main.dart';
import 'package:reference_app/src/call_session.dart';
import 'package:reference_app/src/demo_feeds.dart' show demoQualitySourceLabel;
import 'package:reference_app/src/live_quality_feed.dart'
    show liveQualitySourceLabel;
import 'package:reference_app/src/ui/network_truth.dart';
import 'package:reference_app/src/ui/tokens.dart' show AppMotion;

// ---------------------------------------------------------------------------
// Hand-driven ports. The controller under them is the real one.
// ---------------------------------------------------------------------------

SessionDescription _sdp(SessionDescriptionType type) => SessionDescription(
  type: type,
  sdp: 'v=0\r\no=- 1 1 IN IP4 127.0.0.1\r\ns=${type.name}\r\nt=0 0\r\n',
);

class _Transport implements CallTransport {
  final _events = StreamController<TransportEvent>.broadcast(sync: true);

  @override
  Stream<TransportEvent> get events => _events.stream;

  @override
  Future<void> connect() async {}

  @override
  Future<void> disconnect() async {}
}

class _Signaling implements CallSignaling {
  _Signaling(this.onSend);

  final void Function(SignalingCommand command) onSend;
  final _events = StreamController<SignalingEvent>.broadcast(sync: true);
  final sent = <SignalingCommand>[];

  @override
  Stream<SignalingEvent> get events => _events.stream;

  @override
  Future<void> start({required String callId, required CallRole role}) async {
    // A receiver is answered by the far side's offer, which arrives once
    // signaling is up — on the next microtask, never in this turn.
    if (role == CallRole.receiver) {
      scheduleMicrotask(
        () => emit(RemoteDescriptionEvent(_sdp(SessionDescriptionType.offer))),
      );
    }
  }

  @override
  Future<void> send(SignalingCommand command) async {
    sent.add(command);
    onSend(command);
  }

  @override
  Future<void> stop() async {}

  void emit(SignalingEvent event) => _events.add(event);
}

class _Media implements CallMediaSession {
  final _events = StreamController<MediaEvent>.broadcast(sync: true);

  @override
  MediaConnectionState connectionState = MediaConnectionState.newConnection;

  @override
  MediaSignalingState signalingState = MediaSignalingState.stable;

  @override
  Stream<MediaEvent> get events => _events.stream;

  @override
  Future<void> start() async {}

  @override
  Future<SessionDescription> createOffer({required bool iceRestart}) async =>
      _sdp(SessionDescriptionType.offer);

  @override
  Future<SessionDescription> createAnswer() async =>
      _sdp(SessionDescriptionType.answer);

  @override
  Future<void> setLocalDescription(SessionDescription description) async {
    signalingState = description.type == SessionDescriptionType.offer
        ? MediaSignalingState.haveLocalOffer
        : MediaSignalingState.stable;
    if (description.type == SessionDescriptionType.answer) _connectSoon();
  }

  @override
  Future<void> setRemoteDescription(SessionDescription description) async {
    signalingState = description.type == SessionDescriptionType.offer
        ? MediaSignalingState.haveRemoteOffer
        : MediaSignalingState.stable;
    if (description.type == SessionDescriptionType.answer) _connectSoon();
  }

  /// The engine reports connected once the answer is in place — after the
  /// controller has applied it, never in the same turn as its arrival.
  void _connectSoon() {
    scheduleMicrotask(() {
      connectionState = MediaConnectionState.connected;
      emit(const MediaConnectionChangedEvent(MediaConnectionState.connected));
    });
  }

  @override
  Future<void> addRemoteIceCandidate(IceCandidate candidate) async {}

  @override
  Future<void> rollback() async {}

  @override
  Future<void> stop() async {}

  void emit(MediaEvent event) => _events.add(event);
}

/// One fake session: a real [CallController] whose far side answers every
/// offer on the next microtask and whose media then reports connected.
class _FakeSession {
  _FakeSession({
    required String callId,
    required CallRole role,
    required this.readings,
  }) {
    signaling = _Signaling(_onSend);
    controller = CallController(
      callId: callId,
      role: role,
      transport: transport,
      signaling: signaling,
      media: media,
      reconnectPolicy: ExponentialBackoffReconnectPolicy(),
    );
    handle = CallSessionHandle(
      controller: controller,
      qualityReadings: readings?.stream,
      dispose: () async {
        disposeCalls++;
        await controller.dispose();
      },
    );
  }

  final transport = _Transport();
  late final _Signaling signaling;
  final media = _Media();
  late final CallController controller;
  late final CallSessionHandle handle;

  /// Null models a session build that skips production wiring.
  final StreamController<CallQualityReading>? readings;

  int disposeCalls = 0;

  void _onSend(SignalingCommand command) {
    if (command is SendDescriptionCommand &&
        command.description.type == SessionDescriptionType.offer) {
      scheduleMicrotask(() {
        signaling.emit(
          RemoteDescriptionEvent(_sdp(SessionDescriptionType.answer)),
        );
      });
    }
  }

  void remoteHangUp() => signaling.emit(RemoteHangupEvent('bye'));
}

/// The opener the app is given: records what it was asked for, can be held
/// open, and hands out one [_FakeSession] per call.
class _OpenerProbe {
  _OpenerProbe({this.withReadings = true});

  final bool withReadings;
  final calls = <({String callId, CallRole role})>[];
  final sessions = <_FakeSession>[];

  /// While non-null the opener waits on it, so a test can act mid-open.
  Completer<void>? hold;

  Future<CallSessionHandle?> open({
    required String callId,
    required CallRole role,
  }) async {
    calls.add((callId: callId, role: role));
    final gate = hold;
    if (gate != null) await gate.future;
    final session = _FakeSession(
      callId: callId,
      role: role,
      readings: withReadings
          ? StreamController<CallQualityReading>.broadcast()
          : null,
    );
    sessions.add(session);
    return session.handle;
  }
}

Future<void> _settle(WidgetTester tester, [int frames = 6]) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

/// Tears the app down and lets its disposals run, so a test ends with every
/// handle released and no timer pending.
Future<void> _teardownApp(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await _settle(tester, 3);
}

void main() {
  group('the gauge names its source', () {
    testWidgets(
      'reads "live path stats" while the session supplies readings, charts '
      'them, and never shows the demo label',
      (tester) async {
        final probe = _OpenerProbe()..hold = Completer<void>();
        await tester.pumpWidget(MyApp(openSession: probe.open));
        await tester.pump();

        await tester.tap(find.widgetWithText(FilledButton, 'Call'));
        await tester.pump();
        // Acknowledged before the opener has answered — the controller set
        // this synchronously on the tap.
        expect(find.text('Connecting…'), findsOneWidget);

        probe.hold!.complete();
        await _settle(tester);
        expect(find.text('Connected'), findsOneWidget);
        expect(probe.calls.single.role, CallRole.initiator);
        expect(find.text(liveQualitySourceLabel), findsOneWidget);
        expect(find.text(demoQualitySourceLabel), findsNothing);

        // A measured reading reaches the gauge as the number it carries.
        probe.sessions.single.readings!.add(
          const CallQualityReading(
            at: Duration(seconds: 1),
            rttMs: 42,
            lossFraction: 0.01,
            bitrateBps: 500000,
          ),
        );
        await _settle(tester, 2);
        expect(find.text('42 ms'), findsOneWidget);

        await tester.ensureVisible(
          find.widgetWithText(FilledButton, 'Hang up'),
        );

        await tester.tap(find.widgetWithText(FilledButton, 'Hang up'));
        await _settle(tester);
        expect(find.text('Call ended'), findsOneWidget);
        expect(find.text('You hung up'), findsOneWidget);
        expect(find.text(liveQualitySourceLabel), findsNothing);
        expect(probe.sessions.single.disposeCalls, 1);
        expect(find.widgetWithText(FilledButton, 'Call'), findsOneWidget);

        await _teardownApp(tester);
        expect(probe.sessions.single.disposeCalls, 1);
      },
    );

    testWidgets(
      'reads "synthetic demo profile" when no session supplies readings',
      (tester) async {
        // The demo feed is only handed out with ambient motion on (the
        // production default); the feed's timer stops with its last
        // listener and its dispose, both of which the teardown exercises.
        AppMotion.ambientEnabled = true;
        addTearDown(() => AppMotion.ambientEnabled = false);

        final probe = _OpenerProbe(withReadings: false);
        await tester.pumpWidget(MyApp(openSession: probe.open));
        await tester.pump();

        await tester.tap(find.widgetWithText(FilledButton, 'Call'));
        await _settle(tester);
        expect(find.text('Connected'), findsOneWidget);
        expect(find.text(demoQualitySourceLabel), findsOneWidget);
        expect(find.text(liveQualitySourceLabel), findsNothing);

        await _teardownApp(tester);
        expect(probe.sessions.single.disposeCalls, 1);
      },
    );
  });

  group('the handle is released exactly once', () {
    testWidgets('hanging up while the opener is still in flight abandons '
        'the attempt and disposes the late handle', (tester) async {
      final probe = _OpenerProbe()..hold = Completer<void>();
      await tester.pumpWidget(MyApp(openSession: probe.open));
      await tester.pump();

      await tester.tap(find.widgetWithText(FilledButton, 'Call'));
      await tester.pump();
      expect(find.text('Connecting…'), findsOneWidget);

      await tester.ensureVisible(find.widgetWithText(FilledButton, 'Hang up'));

      await tester.tap(find.widgetWithText(FilledButton, 'Hang up'));
      await tester.pump();
      expect(find.text('Call ended'), findsOneWidget);
      expect(find.text('You hung up'), findsOneWidget);

      // The relay answers late. The handle is disposed, once, and the call
      // stays ended — nothing starts the late session.
      probe.hold!.complete();
      await _settle(tester);
      final late = probe.sessions.single;
      expect(late.disposeCalls, 1);
      expect(late.signaling.sent, isEmpty);
      expect(find.text('Call ended'), findsOneWidget);

      await _teardownApp(tester);
      expect(late.disposeCalls, 1);
    });

    testWidgets('a remote hang-up ends the call with its reason and releases '
        'the handle', (tester) async {
      final probe = _OpenerProbe();
      await tester.pumpWidget(MyApp(openSession: probe.open));
      await tester.pump();

      await tester.tap(find.widgetWithText(FilledButton, 'Call'));
      await _settle(tester);
      expect(find.text('Connected'), findsOneWidget);

      probe.sessions.single.remoteHangUp();
      await _settle(tester);
      expect(find.text('Call ended'), findsOneWidget);
      expect(find.text('The other side hung up'), findsOneWidget);
      expect(probe.sessions.single.disposeCalls, 1);

      await _teardownApp(tester);
      expect(probe.sessions.single.disposeCalls, 1);
    });

    testWidgets('closing the screen mid-call disposes the handle once', (
      tester,
    ) async {
      final probe = _OpenerProbe();
      await tester.pumpWidget(MyApp(openSession: probe.open));
      await tester.pump();

      await tester.tap(find.widgetWithText(FilledButton, 'Call'));
      await _settle(tester);
      expect(find.text('Connected'), findsOneWidget);

      await _teardownApp(tester);
      expect(probe.sessions.single.disposeCalls, 1);
      expect(probe.sessions.single.controller.state.isTerminal, isTrue);
    });
  });

  group('joining', () {
    testWidgets('joins the other side\'s key as the receiver', (tester) async {
      final probe = _OpenerProbe();
      await tester.pumpWidget(MyApp(openSession: probe.open));
      await tester.pump();

      await tester.tap(find.widgetWithText(OutlinedButton, 'Join with key'));
      await _settle(tester, 2);
      // Disabled until the text is a key the relay would accept.
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Join'))
            .onPressed,
        isNull,
      );
      await tester.enterText(
        find.byType(TextField),
        ' AbC-123_xyzAbC-123_xyz ',
      );
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Join'));
      await _settle(tester);

      expect(probe.calls.single.role, CallRole.receiver);
      expect(probe.calls.single.callId, 'AbC-123_xyzAbC-123_xyz');
      expect(find.text('Connected'), findsOneWidget);

      await _teardownApp(tester);
      expect(probe.sessions.single.disposeCalls, 1);
    });

    test('validateCallKey accepts the relay alphabet and nothing else', () {
      expect(validateCallKey(' AbC-123_xyz.ok '), 'AbC-123_xyz.ok');
      expect(validateCallKey(''), isNull);
      expect(validateCallKey('has space'), isNull);
      expect(validateCallKey('slash/no'), isNull);
      expect(validateCallKey('x' * 65), isNull);
    });

    test('joinCall refuses an invalid key before touching any state', () {
      final controller = LiveCallController(
        open: ({required callId, required role}) async => null,
      );
      addTearDown(controller.dispose);
      expect(() => controller.joinCall('not a key'), throwsArgumentError);
      expect(controller.phase, CallPhase.idle);
      expect(controller.callId, isNull);
    });
  });
}
