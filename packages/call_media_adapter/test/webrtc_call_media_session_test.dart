import 'dart:async';

import 'package:call_core/call_core.dart';
import 'package:call_media_adapter/call_media_adapter.dart';
import 'package:media_webrtc/media_webrtc.dart' as mw;
import 'package:test/test.dart';

class _FakeMediaDataChannel implements mw.MediaDataChannel {
  _FakeMediaDataChannel(this.label);

  @override
  final String label;

  @override
  Stream<List<int>> get inbound => const Stream.empty();

  // In-memory fake: nothing ever queues.
  @override
  int? get bufferedAmount => null;

  @override
  Stream<mw.MediaDataChannelState> get state => const Stream.empty();

  @override
  mw.MediaDataChannelState get currentState =>
      mw.MediaDataChannelState.connecting;

  @override
  Future<void> send(List<int> frame) async {}

  @override
  Future<void> close() async {}
}

class FakePeerConnectionPort implements mw.PeerConnectionPort {
  final _statusController =
      StreamController<mw.PeerConnectionStatus>.broadcast();
  final _candidateController = StreamController<mw.IceCandidate>.broadcast();

  int createOfferCalls = 0;
  int createAnswerCalls = 0;
  int setLocalDescriptionCalls = 0;
  int setRemoteDescriptionCalls = 0;
  int addRemoteCandidateCalls = 0;
  int closeCalls = 0;
  mw.DataChannelConfig? lastDataChannelConfig;

  @override
  Future<mw.MediaDataChannel> createDataChannel(
    mw.DataChannelConfig config,
  ) async {
    lastDataChannelConfig = config;
    return _FakeMediaDataChannel(config.label);
  }

  void pushStatus(mw.PeerConnectionStatus status) =>
      _statusController.add(status);

  void pushLocalCandidate(mw.IceCandidate candidate) =>
      _candidateController.add(candidate);

  @override
  Stream<mw.PeerConnectionStatus> get connectionStatus =>
      _statusController.stream;

  @override
  Stream<mw.IceCandidate> get localCandidates => _candidateController.stream;

  @override
  Future<mw.SdpDescription> createOffer({required bool iceRestart}) async {
    createOfferCalls++;
    return mw.SdpDescription(type: 'offer', sdp: 'v=0 offer');
  }

  @override
  Future<mw.SdpDescription> createAnswer() async {
    createAnswerCalls++;
    return mw.SdpDescription(type: 'answer', sdp: 'v=0 answer');
  }

  @override
  Future<void> setLocalDescription(mw.SdpDescription description) async {
    setLocalDescriptionCalls++;
  }

  @override
  Future<void> setRemoteDescription(mw.SdpDescription description) async {
    setRemoteDescriptionCalls++;
  }

  @override
  Future<void> addRemoteCandidate(mw.IceCandidate candidate) async {
    addRemoteCandidateCalls++;
  }

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
    closeCalls++;
  }

  Future<void> disposeStreams() async {
    await _statusController.close();
    await _candidateController.close();
  }
}

void main() {
  group('WebRtcCallMediaSession', () {
    late FakePeerConnectionPort port;
    late int portFactoryCalls;
    late WebRtcCallMediaSession session;

    setUp(() {
      port = FakePeerConnectionPort();
      portFactoryCalls = 0;
      session = WebRtcCallMediaSession(() async {
        portFactoryCalls++;
        return port;
      });
    });

    tearDown(() async {
      await port.disposeStreams();
    });

    test('start() twice is idempotent (second call is a no-op)', () async {
      await session.start();
      expect(portFactoryCalls, 1);
      expect(session.connectionState, MediaConnectionState.connecting);

      await session.start();
      expect(portFactoryCalls, 1);
      expect(session.connectionState, MediaConnectionState.connecting);
    });

    test('stop() twice is safe', () async {
      await session.start();
      await session.stop();
      expect(session.connectionState, MediaConnectionState.closed);

      await session.stop();
      expect(session.connectionState, MediaConnectionState.closed);
    });

    test('addRemoteIceCandidate with a null candidate line is dropped '
        'without a port call', () async {
      await session.start();
      final endOfCandidates = IceCandidate(candidate: null);

      await session.addRemoteIceCandidate(endOfCandidates);

      expect(port.addRemoteCandidateCalls, 0);
    });

    test('any session method after stop() throws StateError', () async {
      await session.start();
      await session.stop();

      final validOffer = SessionDescription(
        type: SessionDescriptionType.offer,
        sdp: 'v=0 offer',
      );
      final validAnswer = SessionDescription(
        type: SessionDescriptionType.answer,
        sdp: 'v=0 answer',
      );
      final realCandidate = IceCandidate(
        candidate: 'candidate:1 1 UDP 1 127.0.0.1 1 typ host',
        sdpMLineIndex: 0,
      );

      await expectLater(session.start(), throwsA(isA<StateError>()));
      await expectLater(
        session.createOffer(iceRestart: false),
        throwsA(isA<StateError>()),
      );
      await expectLater(session.createAnswer(), throwsA(isA<StateError>()));
      await expectLater(
        session.setLocalDescription(validOffer),
        throwsA(isA<StateError>()),
      );
      await expectLater(
        session.setRemoteDescription(validAnswer),
        throwsA(isA<StateError>()),
      );
      await expectLater(
        session.addRemoteIceCandidate(realCandidate),
        throwsA(isA<StateError>()),
      );
      await expectLater(session.rollback(), throwsA(isA<StateError>()));
    });

    test(
      'status mapping covers all five PeerConnectionStatus values',
      () async {
        await session.start();

        final expected = <mw.PeerConnectionStatus, MediaConnectionState>{
          mw.PeerConnectionStatus.connecting: MediaConnectionState.connecting,
          mw.PeerConnectionStatus.connected: MediaConnectionState.connected,
          mw.PeerConnectionStatus.disconnected:
              MediaConnectionState.disconnected,
          mw.PeerConnectionStatus.failed: MediaConnectionState.failed,
          mw.PeerConnectionStatus.closed: MediaConnectionState.closed,
        };

        for (final entry in expected.entries) {
          final changed = session.events.firstWhere(
            (event) => event is MediaConnectionChangedEvent,
          );
          port.pushStatus(entry.key);
          final event = await changed as MediaConnectionChangedEvent;

          expect(event.state, entry.value);
          expect(session.connectionState, entry.value);
        }
      },
    );

    test('local port candidates surface as LocalIceCandidateEvent with '
        'converted fields', () async {
      await session.start();
      final first = session.events.firstWhere(
        (event) => event is LocalIceCandidateEvent,
      );
      port.pushLocalCandidate(
        mw.IceCandidate(
          candidate: 'candidate:x',
          sdpMid: '0',
          sdpMLineIndex: 0,
        ),
      );
      final event = await first as LocalIceCandidateEvent;

      expect(event.candidate.candidate, 'candidate:x');
      expect(event.candidate.sdpMid, '0');
      expect(event.candidate.sdpMLineIndex, 0);
    });

    test('rollback() without a nativeRollback seam resets local signaling '
        'tracking without throwing (documented fallback path)', () async {
      await session.start();
      final offer = SessionDescription(
        type: SessionDescriptionType.offer,
        sdp: 'v=0 offer',
      );
      await session.setLocalDescription(offer);
      expect(session.signalingState, MediaSignalingState.haveLocalOffer);

      await session.rollback();

      expect(session.signalingState, MediaSignalingState.stable);
    });

    test(
      'rollback() invokes the injected nativeRollback with the live port',
      () async {
        mw.PeerConnectionPort? rolledBack;
        final rollbackSession = WebRtcCallMediaSession(
          () async => port,
          nativeRollback: (p) async => rolledBack = p,
        );
        await rollbackSession.start();
        await rollbackSession.setLocalDescription(
          SessionDescription(type: SessionDescriptionType.offer, sdp: 'v=0'),
        );

        await rollbackSession.rollback();

        expect(rolledBack, same(port));
        expect(rollbackSession.signalingState, MediaSignalingState.stable);
        await rollbackSession.stop();
      },
    );

    test('openDataChannel delegates to the port with the negotiated default '
        'config (id 0, ordered, vck-messaging)', () async {
      await session.start();
      final channel = await session.openDataChannel();

      expect(channel.label, 'vck-messaging');
      final config = port.lastDataChannelConfig;
      expect(config, isNotNull);
      expect(config!.negotiatedId, 0);
      expect(config.ordered, isTrue);
    });

    test('openDataChannel before start() throws StateError', () async {
      expect(() => session.openDataChannel(), throwsStateError);
    });
  });
}
