import 'dart:async';

import 'package:media_webrtc/media_webrtc.dart';
import 'package:test/test.dart';

/// Fake [PeerConnectionPort]. `createOffer` behavior is controlled per-test
/// via [offerBehavior]; every other call succeeds immediately with a
/// trivial result so tests can focus on the negotiation guard/timeout.
class FakePeerConnectionPort implements PeerConnectionPort {
  final _statusController = StreamController<PeerConnectionStatus>.broadcast();
  final _candidateController = StreamController<IceCandidate>.broadcast();

  /// When set, `createOffer` awaits this completer instead of returning
  /// immediately (used to simulate a hung platform channel).
  Completer<SdpDescription>? hangOfferOn;

  int createOfferCalls = 0;
  bool? lastIceRestart;
  final List<SdpDescription> remoteDescriptions = [];
  final List<IceCandidate> remoteCandidates = [];

  void pushStatus(PeerConnectionStatus status) => _statusController.add(status);

  void pushLocalCandidate(IceCandidate candidate) =>
      _candidateController.add(candidate);

  @override
  Stream<PeerConnectionStatus> get connectionStatus => _statusController.stream;

  @override
  Stream<IceCandidate> get localCandidates => _candidateController.stream;

  @override
  Future<SdpDescription> createOffer({required bool iceRestart}) async {
    createOfferCalls++;
    lastIceRestart = iceRestart;
    final hang = hangOfferOn;
    if (hang != null) {
      return hang.future;
    }
    return SdpDescription(type: 'offer', sdp: 'v=0 offer');
  }

  @override
  Future<SdpDescription> createAnswer() async =>
      SdpDescription(type: 'answer', sdp: 'v=0 answer');

  @override
  Future<void> setLocalDescription(SdpDescription description) async {}

  @override
  Future<void> setRemoteDescription(SdpDescription description) async {
    remoteDescriptions.add(description);
  }

  @override
  Future<void> addRemoteCandidate(IceCandidate candidate) async {
    remoteCandidates.add(candidate);
  }

  @override
  Future<void> setVideoSenderParameters(
    VideoSenderParameters parameters,
  ) async {}

  @override
  Future<void> setAudioMaxBitrate(int bitrateBps) async {}

  @override
  Future<RawRtcCounters?> readStatsCounters() async => null;

  @override
  Future<void> close() async {}

  Future<void> disposeStreams() async {
    await _statusController.close();
    await _candidateController.close();
  }
}

void main() {
  group('WebRtcMediaEngine.startOffer', () {
    late FakePeerConnectionPort port;
    late WebRtcMediaEngine engine;

    setUp(() {
      port = FakePeerConnectionPort();
      engine = WebRtcMediaEngine(
        port: port,
        operationTimeout: const Duration(milliseconds: 50),
      );
    });

    tearDown(() async {
      await engine.dispose();
      await port.disposeStreams();
    });

    test(
      'throws TimeoutException when createOffer hangs past operationTimeout',
      () async {
        port.hangOfferOn = Completer<SdpDescription>(); // never completes

        await expectLater(
          engine.startOffer(),
          throwsA(isA<TimeoutException>()),
        );
      },
    );

    test(
      'releases the negotiation guard after a timeout so a later call succeeds',
      () async {
        port.hangOfferOn = Completer<SdpDescription>();
        await expectLater(
          engine.startOffer(),
          throwsA(isA<TimeoutException>()),
        );

        // The guard must have been released in the `finally` clause: a
        // subsequent call with a working port must succeed, not throw
        // StateError('Negotiation already in progress.').
        port.hangOfferOn = null;
        final offer = await engine.startOffer();
        expect(offer.type, 'offer');
      },
    );

    test('a concurrent second startOffer while one is in flight throws '
        'StateError', () async {
      port.hangOfferOn = Completer<SdpDescription>(); // keeps first call busy

      final first = engine.startOffer();
      // Give the first call a chance to set the _negotiating guard before
      // the second call is issued.
      await Future<void>.delayed(Duration.zero);

      await expectLater(engine.startOffer(), throwsA(isA<StateError>()));

      // Clean up the still-in-flight first call so it doesn't leak past the
      // test: let it time out on its own.
      await expectLater(first, throwsA(isA<TimeoutException>()));
    });
  });

  group('WebRtcMediaEngine negotiation surface', () {
    late FakePeerConnectionPort port;
    late WebRtcMediaEngine engine;

    setUp(() {
      port = FakePeerConnectionPort();
      engine = WebRtcMediaEngine(
        port: port,
        operationTimeout: const Duration(milliseconds: 50),
      );
    });

    tearDown(() async {
      await engine.dispose();
      await port.disposeStreams();
    });

    test(
      'acceptOffer applies the remote offer and returns a local answer',
      () async {
        final answer = await engine.acceptOffer(
          SdpDescription(type: 'offer', sdp: 'v=0 remote'),
        );

        expect(answer.type, 'answer');
        expect(port.remoteDescriptions.single.sdp, 'v=0 remote');
      },
    );

    test(
      'acceptOffer / acceptAnswer reject a wrong-typed description',
      () async {
        await expectLater(
          engine.acceptOffer(SdpDescription(type: 'answer', sdp: 'v=0')),
          throwsArgumentError,
        );
        await expectLater(
          engine.acceptAnswer(SdpDescription(type: 'offer', sdp: 'v=0')),
          throwsArgumentError,
        );
      },
    );

    test('remote candidates arriving before the remote description are '
        'buffered, then flushed in order', () async {
      const early1 = IceCandidate(candidate: 'candidate:1', sdpMid: '0');
      const early2 = IceCandidate(candidate: 'candidate:2', sdpMid: '0');
      await engine.addRemoteCandidate(early1);
      await engine.addRemoteCandidate(early2);
      expect(
        port.remoteCandidates,
        isEmpty,
        reason: 'no remote description yet — candidates must buffer',
      );

      await engine.acceptAnswer(SdpDescription(type: 'answer', sdp: 'v=0'));
      expect(port.remoteCandidates.map((c) => c.candidate), [
        'candidate:1',
        'candidate:2',
      ]);

      const late1 = IceCandidate(candidate: 'candidate:3', sdpMid: '0');
      await engine.addRemoteCandidate(late1);
      expect(
        port.remoteCandidates.last.candidate,
        'candidate:3',
        reason: 'after the description, candidates apply directly',
      );
    });

    test('restartIce issues an iceRestart offer', () async {
      final offer = await engine.restartIce();
      expect(offer.type, 'offer');
      expect(port.lastIceRestart, isTrue);
    });

    test(
      'every negotiation entry point throws StateError after dispose()',
      () async {
        final disposedPort = FakePeerConnectionPort();
        final disposedEngine = WebRtcMediaEngine(port: disposedPort);
        await disposedEngine.dispose();

        expect(() => disposedEngine.startOffer(), throwsStateError);
        expect(
          () => disposedEngine.acceptOffer(
            SdpDescription(type: 'offer', sdp: 'v=0'),
          ),
          throwsStateError,
        );
        expect(
          () => disposedEngine.addRemoteCandidate(
            const IceCandidate(candidate: 'candidate:1'),
          ),
          throwsStateError,
        );
        await disposedPort.disposeStreams();
      },
    );

    test('connection status events are forwarded, including the benign '
        'connecting/disconnected ones', () async {
      final events = <MediaEngineEvent>[];
      final sub = engine.events.listen(events.add);

      port.pushStatus(PeerConnectionStatus.connecting);
      port.pushStatus(PeerConnectionStatus.disconnected);
      await Future<void>.delayed(Duration.zero);

      expect(events.whereType<MediaConnectionChanged>().map((e) => e.status), [
        PeerConnectionStatus.connecting,
        PeerConnectionStatus.disconnected,
      ]);
      await sub.cancel();
    });

    test(
      'local candidates from the port surface on outgoingCandidates',
      () async {
        final candidates = <IceCandidate>[];
        final sub = engine.outgoingCandidates.listen(candidates.add);

        port.pushLocalCandidate(
          const IceCandidate(candidate: 'candidate:local', sdpMid: '0'),
        );
        await Future<void>.delayed(Duration.zero);

        expect(candidates.single.candidate, 'candidate:local');
        await sub.cancel();
      },
    );
  });

  group('value/config validation', () {
    test('SdpDescription rejects bad types and empty sdp', () {
      expect(
        () => SdpDescription(type: 'pranswer', sdp: 'v=0'),
        throwsArgumentError,
      );
      expect(() => SdpDescription(type: 'offer', sdp: ''), throwsArgumentError);
    });

    test('engine rejects a non-positive operationTimeout', () {
      final port = FakePeerConnectionPort();
      expect(
        () => WebRtcMediaEngine(port: port, operationTimeout: Duration.zero),
        throwsArgumentError,
      );
    });

    test('RtcStatsSampler rejects out-of-range alpha and interval, and '
        'samples render for diagnostics', () {
      expect(
        () => RtcStatsSampler(reader: () async => null, alpha: 0),
        throwsRangeError,
      );
      expect(
        () =>
            RtcStatsSampler(reader: () async => null, interval: Duration.zero),
        throwsArgumentError,
      );

      const sample = RtcStatsSample(
        packetLossFraction: 0.05,
        rttMs: 120,
        jitterMs: 15,
        incomingBitrateBps: 256000,
        outgoingBitrateBps: 512000,
        availableOutgoingBitrateBps: 800000,
        timestampMs: 0,
      );
      expect(sample.toString(), contains('loss: 5.0%'));
      expect(sample.toString(), contains('rtt: 120ms'));
    });
  });
}
