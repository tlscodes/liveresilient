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

  @override
  Stream<PeerConnectionStatus> get connectionStatus => _statusController.stream;

  @override
  Stream<IceCandidate> get localCandidates => _candidateController.stream;

  @override
  Future<SdpDescription> createOffer({required bool iceRestart}) async {
    createOfferCalls++;
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
  Future<void> setRemoteDescription(SdpDescription description) async {}

  @override
  Future<void> addRemoteCandidate(IceCandidate candidate) async {}

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
}
