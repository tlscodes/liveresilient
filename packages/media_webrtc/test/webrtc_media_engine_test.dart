import 'dart:async';

import 'package:fake_async/fake_async.dart';
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

/// Fake [PeerConnectionPort] for the sample-serialization test: every
/// `setVideoSenderParameters` call blocks on a fresh, test-controlled
/// [Completer] so overlap between successive decisions is fully
/// deterministic. `readStatsCounters` replays a fixed, deterministic
/// counters sequence (one entry per poll; the last entry repeats once
/// exhausted) so successive samples are "bad" (high RTT) with monotonic
/// counters -- never a negative or otherwise-rejected delta.
class _SerializingFakePort implements PeerConnectionPort {
  final List<RawRtcCounters> counterSequence;
  int _pollIndex = 0;

  final _statusController = StreamController<PeerConnectionStatus>.broadcast();
  final _candidateController = StreamController<IceCandidate>.broadcast();

  /// One completer per `setVideoSenderParameters` call, in call order.
  final List<Completer<void>> videoCallGates = [];
  final List<int> audioCallsInOrder = [];

  _SerializingFakePort(this.counterSequence);

  void emitStatus(PeerConnectionStatus status) => _statusController.add(status);

  @override
  Stream<PeerConnectionStatus> get connectionStatus => _statusController.stream;

  @override
  Stream<IceCandidate> get localCandidates => _candidateController.stream;

  @override
  Future<SdpDescription> createOffer({required bool iceRestart}) async =>
      SdpDescription(type: 'offer', sdp: 'v=0 offer');

  @override
  Future<SdpDescription> createAnswer() async =>
      SdpDescription(type: 'answer', sdp: 'v=0 answer');

  @override
  Future<void> setLocalDescription(SdpDescription description) async {}

  @override
  Future<void> setRemoteDescription(SdpDescription description) async {}

  @override
  Future<void> addRemoteCandidate(IceCandidate candidate) async {}

  @override
  Future<void> setVideoSenderParameters(
    VideoSenderParameters parameters,
  ) async {
    final gate = Completer<void>();
    videoCallGates.add(gate);
    await gate.future;
  }

  @override
  Future<void> setAudioMaxBitrate(int bitrateBps) async {
    audioCallsInOrder.add(bitrateBps);
  }

  @override
  Future<RawRtcCounters?> readStatsCounters() async {
    final index = _pollIndex.clamp(0, counterSequence.length - 1);
    _pollIndex++;
    return counterSequence[index];
  }

  @override
  Future<void> close() async {}

  Future<void> disposeStreams() async {
    await _statusController.close();
    await _candidateController.close();
  }
}

/// Monotonically increasing, always-"bad" (RTT well above the 600ms
/// downgrade threshold, zero loss) counters for poll number [n] (0-based).
RawRtcCounters _badCounters(int n) => RawRtcCounters(
  packetsReceived: 100 * (n + 1),
  packetsLost: 0,
  packetsSent: 100 * (n + 1),
  bytesReceived: 10000 * (n + 1),
  bytesSent: 10000 * (n + 1),
  jitterSeconds: 0.01,
  currentRoundTripTimeSeconds: 0.7,
);

void main() {
  group('WebRtcMediaEngine._onSample overlap guard', () {
    test('two samples that arrive while a decision is being applied are '
        'serialized (never overlap the port), and a third overwrites the '
        'queued one so only the latest-queued decision is ever applied', () {
      fakeAsync((async) {
        final port = _SerializingFakePort([
          _badCounters(0), // poll 1: baseline only, no delta yet.
          _badCounters(1), // poll 2 -> sample #1 -> decision D1.
          _badCounters(2), // poll 3 -> sample #2 -> queued, then dropped.
          _badCounters(3), // poll 4 -> sample #3 -> overwrites the queue.
        ]);
        final engine = WebRtcMediaEngine(
          port: port,
          policy: AdaptiveMediaPolicy(
            initialProfile: MediaProfile.high,
            config: AdaptiveMediaPolicyConfig(badSamplesToDowngrade: 1),
          ),
          statsInterval: const Duration(seconds: 1),
        );

        final decisions = <MediaPolicyDecision>[];
        engine.events.listen((event) {
          if (event is MediaProfileChanged) decisions.add(event.decision);
        });

        port.emitStatus(PeerConnectionStatus.connected);
        async.flushMicrotasks();

        // Poll 1: baseline only -- no sample, no decision, no port call.
        async.elapse(const Duration(seconds: 1));
        expect(port.videoCallGates, isEmpty);

        // Poll 2 -> sample #1 -> D1 (high -> medium): its
        // setVideoSenderParameters call is left pending (gate open).
        async.elapse(const Duration(seconds: 1));
        expect(port.videoCallGates, hasLength(1));
        expect(
          port.audioCallsInOrder,
          isEmpty,
          reason: 'the audio call waits for the video call to resolve',
        );

        // Poll 3 -> sample #2 arrives while D1's call is still pending:
        // it must be QUEUED, never start a second, overlapping call.
        async.elapse(const Duration(seconds: 1));
        expect(
          port.videoCallGates,
          hasLength(1),
          reason: 'sample #2 must queue behind D1, not overlap it',
        );

        // Poll 4 -> sample #3 arrives before the queued sample #2 was
        // ever taken: it must overwrite the queue slot (latest wins).
        async.elapse(const Duration(seconds: 1));
        expect(
          port.videoCallGates,
          hasLength(1),
          reason: 'sample #3 must also queue -- still zero overlap',
        );

        // Resolve D1's call: finishing it must apply exactly the LATEST
        // queued sample (#3), never the discarded #2.
        port.videoCallGates[0].complete();
        async.flushMicrotasks();
        expect(
          port.videoCallGates,
          hasLength(2),
          reason: 'exactly one more call starts, for the latest sample',
        );
        expect(port.audioCallsInOrder, hasLength(1));

        port.videoCallGates[1].complete();
        async.flushMicrotasks();
        expect(port.audioCallsInOrder, hasLength(2));

        expect(
          decisions,
          hasLength(2),
          reason:
              'sample #2 must never have reached the policy or the port '
              '-- only D1 and the latest-queued decision apply',
        );
        expect(decisions[0].next, MediaProfile.medium); // D1.
        expect(
          decisions[1].next,
          MediaProfile.low,
          reason:
              'the policy only ever advanced by D1 then this one step '
              '(medium -> low); had #2 also been applied it would have '
              'reached minimal instead',
        );

        unawaited(engine.dispose());
        unawaited(port.disposeStreams());
        async.flushMicrotasks();
      });
    });
  });

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
