import 'package:media_webrtc/media_webrtc.dart';
import 'package:test/test.dart';

/// Ticket 1 gates 1a and 1e, plus the binding refusal.
///
/// 1a puts `cbr=1` on the wire. 1e stops treating silence handling as a knob
/// somebody sets by hand: DTX and constant bitrate are the two answers to one
/// question, and which is correct follows from whether an emitter is running
/// its own clock. The refusal is what makes constant bitrate safe — without
/// it, the nominal rate becomes the sustained rate on a link measured not to
/// carry it.
const _offer = 'v=0\r\n'
    'm=audio 9 UDP/TLS/RTP/SAVPF 96\r\n'
    'a=rtpmap:96 opus/48000/2\r\n'
    'a=fmtp:96 minptime=10\r\n';

void main() {
  group('gate 1a — constant bitrate reaches the wire', () {
    test('cbr=1 is written only when asked for', () {
      expect(
        applyOpusPolicy(_offer, const OpusSdpPolicy(constantBitrate: true)),
        contains('cbr=1'),
      );
      expect(
        applyOpusPolicy(_offer, const OpusSdpPolicy()),
        isNot(contains('cbr=')),
      );
    });

    test('applying it twice yields the same string', () {
      const policy = OpusSdpPolicy(
        constantBitrate: true,
        maxAverageBitrateBps: 16000,
        ptimeMs: 60,
      );
      final once = applyOpusPolicy(_offer, policy);
      expect(applyOpusPolicy(once, policy), once);
    });

    test('keys the policy does not own are preserved', () {
      final out = applyOpusPolicy(
        _offer,
        const OpusSdpPolicy(constantBitrate: true),
      );
      expect(out, contains('minptime=10'));
    });

    test('a policy that sets only cbr is not a no-op', () {
      expect(
        const OpusSdpPolicy(
          inbandFec: false,
          constantBitrate: true,
        ).isNoop,
        isFalse,
      );
      expect(const OpusSdpPolicy(inbandFec: false).isNoop, isTrue);
    });
  });

  group('gate 1e — silence handling follows the shaping state', () {
    test('an emitter running means constant bitrate on, DTX off', () {
      final policy = OpusSdpPolicy.forShapingState(
        fixedTickEmitterRunning: true,
        maxAverageBitrateBps: 16000,
        ptimeMs: 60,
      );
      expect(policy.constantBitrate, isTrue);
      expect(policy.dtx, isFalse);

      final sdp = applyOpusPolicy(_offer, policy);
      expect(sdp, contains('cbr=1'));
      expect(sdp, isNot(contains('usedtx=')));
    });

    test('no emitter means DTX on, constant bitrate off — today\'s behaviour',
        () {
      final policy = OpusSdpPolicy.forShapingState(
        fixedTickEmitterRunning: false,
        maxAverageBitrateBps: 16000,
        ptimeMs: 60,
      );
      expect(policy.dtx, isTrue);
      expect(policy.constantBitrate, isFalse);

      final sdp = applyOpusPolicy(_offer, policy);
      expect(sdp, contains('usedtx=1'));
      expect(sdp, isNot(contains('cbr=')));
    });

    test(
      'the two are mutually exclusive by construction, not by convention',
      () {
        expect(
          () => OpusSdpPolicy(dtx: true, constantBitrate: true),
          throwsA(isA<AssertionError>()),
          reason: 'suppressing output during silence is exactly what makes '
              'the rate content-dependent; asking for both is incoherent',
        );
      },
    );
  });

  group('the binding refusal', () {
    test(
      'a refused link produces an exception carrying its cause and numbers, '
      'and there is no cheapest-candidate path left to fall back to',
      () {
        final admission = OpusWireBudget.forBandwidth(
          16000,
          concurrentStreams: 2,
          carrier: WireCarrier.heavyFramed,
        );
        final refusal = admission as OpusWireNoCandidateFits;
        final error = CallAdmissionRefused(refusal);

        expect(error.refusal.cause, OpusWireRefusalCause.capacity);
        expect(
          error.toString(),
          allOf(
            contains('${refusal.bandwidthBps}'),
            contains('${refusal.minimumBandwidthBps}'),
          ),
          reason: 'a refusal the user cannot act on is not much better than '
              'a silent downgrade',
        );
      },
    );

    test(
      'a responsiveness refusal says so, because lowering the rate cannot '
      'help a long path',
      () {
        final admission = OpusWireBudget.forBandwidth(
          1000000,
          concurrentStreams: 2,
          tickProbe: ({
            required int wireRateBps,
            required double perStreamBudgetBps,
            required int frameBitsOnWire,
          }) => false,
        );
        final error = CallAdmissionRefused(
          admission as OpusWireNoCandidateFits,
        );
        expect(error.refusal.cause, OpusWireRefusalCause.responsiveness);
        expect(error.toString(), contains('does not shorten a round trip'));
      },
    );
  });
}
