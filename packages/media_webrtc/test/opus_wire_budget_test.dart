import 'package:media_webrtc/media_webrtc.dart';
import 'package:test/test.dart';

/// The measured T2 rows were captured over plain RTP/UDP/IP, so the
/// assertions that reproduce them name that carrier explicitly. The default
/// carrier is deliberately the heavier framing (ticket 1, gate 1b): a call
/// that has not yet learned its carrier must be priced pessimistically.
const _measured = WireCarrier.rtpUdpIp;

OpusWireBudget _fitted(
  int? bw, {
  int streams = 1,
  WireCarrier carrier = _measured,
}) {
  final admission = OpusWireBudget.forBandwidth(
    bw,
    concurrentStreams: streams,
    carrier: carrier,
  );
  expect(
    admission,
    isA<OpusWireFitted>(),
    reason: 'bw=$bw streams=$streams carrier=$carrier was expected to fit',
  );
  return (admission as OpusWireFitted).budget;
}

void main() {
  group('OpusWireBudget', () {
    test('unknown link is unconstrained, which is not a refusal', () {
      for (final bw in [null, 0, -1]) {
        final admission = OpusWireBudget.forBandwidth(bw);
        expect(admission, isA<OpusWireUnconstrained>());
        final b = (admission as OpusWireUnconstrained).budget;
        expect(b.opusRateBps, 32000);
        expect(b.ptimeMs, 20);
        expect(b.occupancy, isNull);
      }
    });

    test(
      'property: a fitted result is always under 70% of the per-stream share, '
      'and anything else is an explicit refusal carrying its numbers',
      () {
        for (var bw = 8000; bw <= 128000; bw += 500) {
          final admission = OpusWireBudget.forBandwidth(bw, carrier: _measured);
          switch (admission) {
            case OpusWireFitted(:final budget):
              expect(
                budget.chosenWireRateBps,
                lessThanOrEqualTo(OpusWireBudget.occupancyCeiling * bw),
                reason: 'bw=$bw chose $budget',
              );
            case OpusWireNoCandidateFits(
                  :final bandwidthBps,
                  :final cheapestWireRateBps,
                  :final minimumBandwidthBps,
                ):
              expect(bandwidthBps, bw);
              expect(
                cheapestWireRateBps,
                greaterThan(OpusWireBudget.occupancyCeiling * bw),
                reason: 'a refusal must be justified by the arithmetic',
              );
              expect(
                minimumBandwidthBps,
                greaterThan(bw),
                reason: 'the quoted minimum must exceed the measured link',
              );
              expect(
                OpusWireBudget.forBandwidth(
                  minimumBandwidthBps,
                  carrier: _measured,
                ),
                isA<OpusWireFitted>(),
                reason: 'the quoted minimum must actually be admitted',
              );
            case OpusWireUnconstrained():
              fail('bw=$bw is a known link; unconstrained is wrong');
          }
        }
      },
    );

    test('property: ptime and rate only ever take candidate values', () {
      for (var bw = 8000; bw <= 128000; bw += 1000) {
        final admission = OpusWireBudget.forBandwidth(bw, carrier: _measured);
        if (admission is! OpusWireFitted) continue;
        final b = admission.budget;
        expect(OpusWireBudget.ptimeCandidatesMs, contains(b.ptimeMs));
        expect(OpusWireBudget.rateCandidatesBps, contains(b.opusRateBps));
      }
    });

    test('property: monotone — more bandwidth never chooses a lower rate', () {
      var lastRate = 0;
      for (var bw = 8000; bw <= 128000; bw += 500) {
        final admission = OpusWireBudget.forBandwidth(bw, carrier: _measured);
        if (admission is! OpusWireFitted) continue;
        final rate = admission.budget.opusRateBps;
        expect(rate, greaterThanOrEqualTo(lastRate), reason: 'bw=$bw');
        lastRate = rate;
      }
    });

    test('the measured T2 profiles get survivable configurations', () {
      // bandwidth profile: 32 kbit/s claim. The failing run's default Opus
      // demanded ~56 kbit/s wire; the model must fit under 22.4k.
      final bandwidth = _fitted(32000);
      expect(bandwidth.chosenWireRateBps, lessThanOrEqualTo(22400));
      expect(bandwidth.opusRateBps, 16000);
      expect(bandwidth.ptimeMs, 60);

      // narrow / extreme: 16 kbit/s claim -> low rate, longer packets.
      // (8000 bps at ptime 120 = 10667 bps wire, 67% of the link. Ptime 100
      // used to win this cell on paper, but libwebrtc quantizes 100 down to
      // the supported 60 ms — realized wire 13333 bps, 83% — so the model
      // now only offers frame lengths the encoder can actually produce.)
      final narrow = _fitted(16000);
      expect(narrow.chosenWireRateBps, lessThanOrEqualTo(11200));
      expect(narrow.opusRateBps, 8000);
      expect(narrow.ptimeMs, 120);

      // Unshaped LAN: full quality, default latency.
      final clean = _fitted(10000000);
      expect(clean.opusRateBps, 32000);
      expect(clean.ptimeMs, 20);
    });

    test('capAudioBitrate caps rungs at the derived rate, never raises', () {
      final b = _fitted(32000); // opus 16000
      expect(b.capAudioBitrate(32000), 16000);
      expect(b.capAudioBitrate(6000), 6000);
    });

    group('gate 1b — per-packet overhead follows the carrier', () {
      test('the assumed carrier is a heavy one, and is NOT the heaviest — '
          'a recorded decision, pinned here so it cannot drift silently', () {
        expect(WireCarrier.assumed, WireCarrier.heavyFramed);
        expect(WireCarrier.rtpUdpIp.headerBitsPerPacket, 320);
        expect(WireCarrier.heavyFramed.headerBitsPerPacket, 528);
        // Added 2026-08-17 with the under-count finding. The default was
        // deliberately NOT promoted: doing so changes which configurations
        // are admitted everywhere and invalidates rows measured under the
        // current default, so it needs a re-run of the shaped matrix.
        expect(WireCarrier.srtpOverIpv6.headerBitsPerPacket, 688);
        expect(
          WireCarrier.srtpOverIpv6.headerBytes -
              WireCarrier.heavyFramed.headerBytes,
          20,
          reason: 'the difference is exactly the IPv6 header minus the IPv4 '
              'one, which is the whole content of the third case',
        );
        expect(
          WireCarrier.values
              .map((c) => c.headerBytes)
              .reduce((a, b) => a > b ? a : b),
          WireCarrier.srtpOverIpv6.headerBytes,
          reason: 'if a heavier case is ever added, this assertion fails and '
              'the default has to be reconsidered deliberately',
        );
      });

      test('the floor case is the cheapest, so an unannotated call can never '
          'be priced below it', () {
        // The measured rows were captured under the floor. Pinning the
        // ordering means a later edit to any headerBytes value that would
        // make the floor no longer the floor shows up as a failing test
        // rather than as a quietly different admission table.
        final cheapest = WireCarrier.values
            .map((c) => c.headerBytes)
            .reduce((a, b) => a < b ? a : b);
        expect(cheapest, WireCarrier.rtpUdpIp.headerBytes);
        expect(
          WireCarrier.assumed.headerBytes,
          greaterThan(cheapest),
          reason: 'the default must never be the optimistic case',
        );
      });

      test('the third case changes admission, which is why it was added '
          'rather than substituted', () {
        // A carrier case that changed no decision would be documentation,
        // not a model term. Both numbers below were MEASURED with
        // example/probe_admission.dart on this code, not predicted: the
        // first draft of this test asserted a refusal at 24000 and was
        // wrong, which is exactly why the tool exists.
        //
        //   heavyFramed   bw=24000 -> rate=12000 ptime=120
        //   srtpOverIpv6  bw=24000 -> rate=10000 ptime=120
        //   heavyFramed   bw=16000 -> rate=6000  ptime=120
        //   srtpOverIpv6  bw=16000 -> refused, capacity, min=16762
        final ipv4At24k = OpusWireBudget.forBandwidth(
          24000,
          carrier: WireCarrier.heavyFramed,
        );
        final ipv6At24k = OpusWireBudget.forBandwidth(
          24000,
          carrier: WireCarrier.srtpOverIpv6,
        );
        expect((ipv4At24k as OpusWireFitted).budget.opusRateBps, 12000);
        expect(
          (ipv6At24k as OpusWireFitted).budget.opusRateBps,
          10000,
          reason: 'the same link buys a lower codec rate once the heavier '
              'framing is priced — the cost lands on quality first',
        );

        // And there is a band where the difference is admission itself.
        expect(
          OpusWireBudget.forBandwidth(
            16000,
            carrier: WireCarrier.heavyFramed,
          ),
          isA<OpusWireFitted>(),
        );
        final refused = OpusWireBudget.forBandwidth(
          16000,
          carrier: WireCarrier.srtpOverIpv6,
        );
        expect(refused, isA<OpusWireNoCandidateFits>());
        expect(
          (refused as OpusWireNoCandidateFits).minimumBandwidthBps,
          16762,
          reason: 'the refusal names the bandwidth that would fix it, from '
              'the same formula the search used',
        );
      });

      test('an unannotated call is priced pessimistically, never optimistically',
          () {
        for (final ptime in OpusWireBudget.ptimeCandidatesMs) {
          expect(
            OpusWireBudget.wireRateBps(6000, ptime),
            OpusWireBudget.wireRateBps(
              6000,
              ptime,
              carrier: WireCarrier.heavyFramed,
            ),
            reason: 'the default must equal the heavier carrier',
          );
          expect(
            OpusWireBudget.wireRateBps(6000, ptime),
            greaterThan(
              OpusWireBudget.wireRateBps(
                6000,
                ptime,
                carrier: WireCarrier.rtpUdpIp,
              ),
            ),
          );
        }
      });

      test(
        'the derived floor moves with the carrier, and is never a literal',
        () {
          // Duplex: both microphones cross the same pipe.
          int floorFor(WireCarrier carrier) {
            final refused = OpusWireBudget.forBandwidth(
              1000,
              concurrentStreams: 2,
              carrier: carrier,
            );
            return (refused as OpusWireNoCandidateFits).minimumBandwidthBps!;
          }

          final light = floorFor(WireCarrier.rtpUdpIp);
          final heavy = floorFor(WireCarrier.heavyFramed);

          expect(
            heavy,
            greaterThan(light),
            reason: 'heavier framing must raise the bar, not lower it',
          );
          // Reproduces the plan's derivation without hardcoding it: the
          // cheapest candidate is the floor rate at the longest ptime.
          for (final (carrier, floor) in [
            (WireCarrier.rtpUdpIp, light),
            (WireCarrier.heavyFramed, heavy),
          ]) {
            final cheapest = OpusWireBudget.wireRateBps(
              OpusWireBudget.rateCandidatesBps.last,
              OpusWireBudget.ptimeCandidatesMs.last,
              carrier: carrier,
            );
            expect(
              floor,
              closeTo(cheapest * 2 / OpusWireBudget.occupancyCeiling, 2),
              reason: 'floor must be derived, not asserted',
            );
            expect(
              OpusWireBudget.forBandwidth(
                floor,
                concurrentStreams: 2,
                carrier: carrier,
              ),
              isA<OpusWireFitted>(),
            );
          }
        },
      );

      test(
        'admission is ONE decision: a wide but slow link is refused for '
        'responsiveness, never for capacity',
        () {
          // 1 Mbit/s of bandwidth — every candidate clears the ceiling with
          // room to spare — but the injected bound rejects each one, the way
          // a 2000 ms round trip does: 150ms - 1000ms - 60ms is negative and
          // no rate change shortens a round trip.
          final admission = OpusWireBudget.forBandwidth(
            1000000,
            concurrentStreams: 2,
            tickProbe: ({
              required int wireRateBps,
              required double perStreamBudgetBps,
              required int frameBitsOnWire,
            }) => false,
          );
          expect(admission, isA<OpusWireNoCandidateFits>());
          final refusal = admission as OpusWireNoCandidateFits;
          expect(
            refusal.cause,
            OpusWireRefusalCause.responsiveness,
            reason: 'reporting capacity here would send the caller to lower '
                'the rate, which cannot help — the path is long, not narrow',
          );
          expect(
            refusal.cheapestWireRateBps,
            lessThan(refusal.perStreamBudgetBps),
            reason: 'the arithmetic must show capacity was never the problem',
          );
        },
      );

      test(
        'a narrow link is still refused for capacity even with a probe that '
        'would have accepted',
        () {
          final admission = OpusWireBudget.forBandwidth(
            16000,
            concurrentStreams: 2,
            carrier: WireCarrier.heavyFramed,
            tickProbe: ({
              required int wireRateBps,
              required double perStreamBudgetBps,
              required int frameBitsOnWire,
            }) => true,
          );
          final refusal = admission as OpusWireNoCandidateFits;
          expect(refusal.cause, OpusWireRefusalCause.capacity);
        },
      );

      test('an absent probe leaves behaviour exactly as it was', () {
        for (final bw in [16000, 32000, 64000, 1000000]) {
          final withoutProbe = OpusWireBudget.forBandwidth(
            bw,
            concurrentStreams: 2,
          );
          final permissiveProbe = OpusWireBudget.forBandwidth(
            bw,
            concurrentStreams: 2,
            tickProbe: ({
              required int wireRateBps,
              required double perStreamBudgetBps,
              required int frameBitsOnWire,
            }) => true,
          );
          expect(
            permissiveProbe.runtimeType,
            withoutProbe.runtimeType,
            reason: 'bw=$bw',
          );
        }
      });

      test('frame bits are derived from the candidate, not passed in', () {
        // One 120 ms frame at 6000 bps carries 720 payload bits, plus the
        // carrier's framing.
        expect(
          OpusWireBudget.frameBitsOnWire(
            6000,
            120,
            carrier: WireCarrier.rtpUdpIp,
          ),
          720 + 320,
        );
        expect(
          OpusWireBudget.frameBitsOnWire(6000, 120),
          720 + 528,
          reason: 'the default carrier is the heavier one here too',
        );
      });

      test(
        'a duplex call on a narrow link is refused, not silently downgraded',
        () {
          final admission = OpusWireBudget.forBandwidth(
            16000,
            concurrentStreams: 2,
            carrier: WireCarrier.heavyFramed,
          );
          expect(
            admission,
            isA<OpusWireNoCandidateFits>(),
            reason: 'this is the row that used to return the cheapest '
                'candidate anyway and queue the link to death',
          );
          final refusal = admission as OpusWireNoCandidateFits;
          expect(refusal.bandwidthBps, 16000);
          expect(refusal.perStreamBudgetBps, closeTo(0.7 * 16000 / 2, 0.001));
          expect(
            refusal.cheapestWireRateBps,
            greaterThan(refusal.perStreamBudgetBps),
          );
        },
      );
    });
  });
}
