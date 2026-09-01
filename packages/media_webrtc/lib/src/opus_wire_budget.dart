/// Wire-budget model: what Opus configuration a known link can SURVIVE.
///
/// WHY THIS EXISTS. Measured 2026-08-06 on the T2 rig (bandwidth profile,
/// 32 kbit/s link): a default Opus stream saturated the pipe, the signaling
/// acks queued 1.6 s deep behind it on a 43 ms path, 19 of 20 probes
/// starved, liveness declared the socket dead and the call died mid-hold.
/// The audio itself killed the call. The missing piece was not a knob —
/// every knob existed — but a MODEL connecting the known link capacity to
/// (codec rate, packet size) BEFORE damage is measured.
///
/// The model: an Opus stream's wire rate is
///
///   wire(rate, ptime, carrier) =
///       rate + carrier.headerBitsPerPacket * (1000 / ptime)
///
/// where the carrier names the per-packet framing the path imposes: 40 B of
/// plain RTP + UDP + IP, or 66 B under the heavier framing ([WireCarrier]).
/// Until the network layer has reported the carrier, the HEAVIER one is
/// assumed: under-estimating overhead over-subscribes the link, a silent
/// failure; over-estimating can only refuse a call that might have fitted,
/// and the admission result reports its numbers, so that error is visible.
/// The chosen configuration must keep
///
///   wire(rate, ptime, carrier) <= occupancyCeiling * bandwidth  (= 0.7)
///
/// The remaining 30% is NOT slack: it is the control plane's survival
/// margin — signaling heartbeats, acks, ICE consent, RTCP — the traffic
/// whose starvation was measured to kill the call. Audio never gets it.
///
/// Pure and deterministic so it is provable without a device: the search
/// prefers the highest codec rate, then the smallest ptime that carries it
/// (larger packets cut header overhead but add latency — they are a price,
/// paid only when the link demands it).
library;

/// Per-packet framing a path imposes on the audio stream.
///
/// A packet's wire cost is its payload plus this framing, so the carrier is
/// a parameter of the wire-rate model, not a constant of it: the same
/// (rate, ptime) pair costs more on a path that wraps every packet in
/// heavier framing.
enum WireCarrier {
  /// Plain RTP over UDP over IPv4: 12 + 8 + 20 = 40 bytes per packet.
  ///
  /// This is the FLOOR of the model, not a description of a WebRTC audio
  /// packet. It omits the SRTP authentication tag, every negotiated header
  /// extension, and the extra 20 bytes an IPv6 header costs — see
  /// [srtpOverIpv6] for the terms. Naming it accurately matters because the
  /// measured T2 rows in `tools/t2/h2_results.tsv` were captured while this
  /// figure was the only one the code had, which means those rows priced
  /// the wire optimistically. Their provenance is recorded, and the reason
  /// no per-row correction is possible, in `tools/t2/CARRIER_PROVENANCE.md`.
  rtpUdpIp(headerBytes: 40),

  /// SRTP with negotiated header extensions over IPv4: 66 bytes per packet.
  ///
  /// ESTIMATE, derived from specifications rather than from a capture on
  /// this stack — the same terms as [srtpOverIpv6] with a 20-byte IPv4
  /// header in place of the 40-byte IPv6 one. That the arithmetic lands
  /// exactly on the 66 this enum already carried is corroboration, not
  /// proof: the figure predates the derivation.
  heavyFramed(headerBytes: 66),

  /// SRTP with negotiated header extensions over IPv6: 86 bytes per packet.
  ///
  /// ADDED 2026-08-17, and added rather than substituted on purpose. The
  /// open finding was that 40 bytes may under-count auth tags, negotiated
  /// extensions and IPv6. Editing [rtpUdpIp] in place would have silently
  /// invalidated every measured row captured under it while those rows
  /// still read as measurements, so the correction arrives as a third case
  /// and the rows keep pointing at the case they actually used.
  ///
  /// Term by term, each from its specification — so the whole figure is an
  /// ESTIMATE until a packet capture on this stack confirms it:
  ///
  /// ```
  /// RTP fixed header                     12   RFC 3550 §5.1
  /// one-byte header extensions           16   RFC 8285: 4 profile+length,
  ///                                           plus transport-wide-cc (3),
  ///                                           abs-send-time (4) and mid (4)
  ///                                           as WebRTC negotiates them for
  ///                                           audio, padded to 4 bytes
  /// SRTP auth tag, HMAC-SHA1-80          10   RFC 3711 §3.4
  /// UDP header                            8   RFC 768
  /// IPv6 fixed header                    40   RFC 8200 §3
  ///                                      --
  ///                                      86
  /// ```
  ///
  /// What would replace this estimate: a capture of one call's audio
  /// packets, taking the median on-wire size minus the payload size the
  /// encoder reported. Until then a caller that KNOWS its path is IPv6
  /// should name this case; nothing selects it automatically, because
  /// nothing in this package can observe the address family.
  srtpOverIpv6(headerBytes: 86);

  const WireCarrier({required this.headerBytes});

  /// Per-packet framing cost in bytes.
  final int headerBytes;

  /// Per-packet framing cost in bits — the figure the wire-rate model uses.
  int get headerBitsPerPacket => headerBytes * 8;

  /// The carrier assumed whenever the network layer has not yet reported
  /// one — never null, never zero.
  ///
  /// Under-estimating overhead over-subscribes the link, which is a silent
  /// failure: the queue builds unseen and kills both directions.
  /// Over-estimating only refuses a call that might have fitted, and the
  /// admission result reports the numbers behind the refusal, so that
  /// error is visible and correctable. That asymmetry is why the default
  /// is a heavy case rather than the floor.
  ///
  /// IT IS NO LONGER THE HEAVIEST CASE IN THIS ENUM, and that is a recorded
  /// decision rather than an oversight. [srtpOverIpv6] is heavier by 20
  /// bytes. Promoting it to the default would change which configurations
  /// are admitted on every existing deployment and would invalidate the
  /// green rows that were measured under this default — so it is a separate,
  /// dated decision that requires a re-run of the shaped-network matrix, not
  /// a one-word edit here. Until that run happens the default stays put and
  /// this paragraph is the honest statement of what it does and does not
  /// bound.
  static const WireCarrier assumed = heavyFramed;
}

/// Why an admission was refused. Two causes exist because the caller's
/// remedy differs:
///
///  - [capacity] is answered by a lower rate or a different codec — the
///    refusal is a function of how many bits the stream offers.
///  - [responsiveness] is answered by neither, because it does not depend
///    on rate: it is a function of the path's delay. Offering fewer bits
///    does not shorten a round trip.
enum OpusWireRefusalCause {
  /// No candidate's wire rate fits under the per-stream share of the
  /// link: the pipe is too narrow for even the cheapest candidate.
  capacity,

  /// At least one candidate fit under the ceiling but was rejected by the
  /// caller's [TickIntervalProbe]: the path is too long, not too narrow.
  /// Bandwidth was ample; no tick interval exists at this delay.
  responsiveness,
}

/// Answers, for ONE concrete candidate, whether a tick interval exists
/// for it.
///
/// This package prices what a candidate costs the wire. Whether the
/// emitter's fixed tick interval has room under the interactive delay
/// budget is a bound this package cannot compute — it depends on the
/// path's one-way delay, which this package never sees. The caller
/// injects that bound here so admission stays ONE decision with named
/// causes. The defect this removes: two components each holding a veto
/// with no defined precedence, so a link with ample bandwidth was
/// admitted here and then refused elsewhere, purely because the round
/// trip was long.
///
/// The probe receives what a tick bound needs and cannot get from this
/// package's constants alone:
///  - [wireRateBps]: the candidate's wire rate, headers included.
///  - [perStreamBudgetBps]: the share of the link this stream is allowed.
///  - [frameBitsOnWire]: bits ONE frame of this candidate puts on the
///    wire ([OpusWireBudget.frameBitsOnWire]).
///
/// Returns true when a tick interval exists for the candidate.
typedef TickIntervalProbe =
    bool Function({
      required int wireRateBps,
      required double perStreamBudgetBps,
      required int frameBitsOnWire,
    });

/// The result of asking whether a link admits an audio stream.
///
/// Exactly three outcomes exist. There is deliberately no "closest anyway"
/// case and no sentinel value: under a constant-rate requirement the
/// nominal rate IS the sustained rate, so a budget the pipe cannot carry is
/// not a degraded call — it is an unbounded queue and the death of both
/// directions.
sealed class OpusWireAdmission {
  const OpusWireAdmission();
}

/// A candidate fits: [budget] is the survivable configuration.
final class OpusWireFitted extends OpusWireAdmission {
  const OpusWireFitted(this.budget);

  /// The chosen configuration.
  final OpusWireBudget budget;
}

/// The link is unknown (bandwidth null or non-positive). This is NOT a
/// refusal: the ladder's standard configuration applies, exactly as it
/// always has for an unknown link.
final class OpusWireUnconstrained extends OpusWireAdmission {
  const OpusWireUnconstrained();

  /// The configuration an unknown link gets: [OpusWireBudget.unconstrained].
  OpusWireBudget get budget => OpusWireBudget.unconstrained;
}

/// No candidate is admitted. The call is refused, carrying [cause] — why —
/// and the numbers a caller needs to report what would have been enough.
/// A link too narrow or too long is an ordinary condition, so this is a
/// value — never a throw.
final class OpusWireNoCandidateFits extends OpusWireAdmission {
  const OpusWireNoCandidateFits({
    required this.cause,
    required this.bandwidthBps,
    required this.perStreamBudgetBps,
    required this.cheapestWireRateBps,
    required this.minimumBandwidthBps,
  });

  /// Why the refusal happened. Named because the caller's remedy differs:
  /// a [OpusWireRefusalCause.capacity] refusal is answered by a lower rate
  /// or a different codec; a [OpusWireRefusalCause.responsiveness] refusal
  /// is answered by neither, since it does not depend on rate.
  final OpusWireRefusalCause cause;

  /// The measured link capacity the admission ran against.
  final int bandwidthBps;

  /// The share of the link one stream was allowed:
  /// occupancyCeiling * bandwidth / concurrentStreams.
  final double perStreamBudgetBps;

  /// Wire rate of the cheapest candidate under the carrier in force — the
  /// least this link would have had to carry per stream.
  final int cheapestWireRateBps;

  /// NULL under [OpusWireRefusalCause.responsiveness], and that absence is
  /// the honest answer rather than an omission.
  ///
  /// Under that cause the link's bandwidth was never the problem: no
  /// bandwidth makes a tick interval exist on a path that long. A number
  /// here would answer a question the caller did not ask and send them to
  /// buy capacity that changes nothing. The field is nullable so the
  /// absence has to be handled, instead of a plausible figure being read
  /// and quoted.
  ///
  /// Under [OpusWireRefusalCause.capacity] it is the smallest link
  /// bandwidth at which that cheapest candidate WOULD
  /// have been admitted, computed from the constants at call time: the
  /// exact threshold a caller can quote as "what this link needs".
  final int? minimumBandwidthBps;
}

/// Thrown when a caller that must have a configuration is handed an
/// [OpusWireNoCandidateFits].
///
/// The admission itself is a value, not a throw, because a narrow or long
/// link is an ordinary condition and the decision belongs to the caller.
/// This exists for the one caller who cannot continue without a
/// configuration — a session builder — so the refusal reaches the user as a
/// refusal carrying its numbers, rather than as a call placed at a rate the
/// measurement says the link cannot sustain.
final class CallAdmissionRefused implements Exception {
  const CallAdmissionRefused(this.refusal);

  /// The refusal, with its cause and its numbers.
  final OpusWireNoCandidateFits refusal;

  @override
  String toString() {
    final need = refusal.minimumBandwidthBps;
    final have = refusal.bandwidthBps;
    return switch (refusal.cause) {
      OpusWireRefusalCause.capacity =>
        'CallAdmissionRefused: the link carries $have bps; the cheapest '
            'configuration needs ${refusal.cheapestWireRateBps} bps per '
            'stream, so $need bps is the minimum that would be admitted.',
      OpusWireRefusalCause.responsiveness =>
        'CallAdmissionRefused: the link has ample capacity ($have bps) but '
            'no emitter tick fits inside the interactive delay budget on a '
            'path this long. A lower rate does not shorten a round trip.',
    };
  }
}

/// One survivable Opus configuration for a known link.
final class OpusWireBudget {
  const OpusWireBudget._({
    required this.opusRateBps,
    required this.ptimeMs,
    required this.bandwidthBps,
    required this.carrier,
  });

  /// Chosen Opus average-bitrate ceiling.
  final int opusRateBps;

  /// Chosen packetization time.
  final int ptimeMs;

  /// The link capacity this budget was derived for; null = unknown link.
  final int? bandwidthBps;

  /// Per-packet framing this budget was priced under. [chosenWireRateBps]
  /// and [occupancy] are computed with it, so what the budget reports is
  /// exactly what the admission checked.
  final WireCarrier carrier;

  /// Per-packet cost of the plain 40-byte carrier, in bits.
  ///
  /// Retained so existing call sites keep their meaning — this member has
  /// always been the 40-byte figure — but derived from
  /// [WireCarrier.rtpUdpIp] so the byte count has a single source. New
  /// code takes the carrier from the network layer (or falls back to
  /// [WireCarrier.assumed]) instead of reading this directly.
  static int get headerBitsPerPacket =>
      WireCarrier.rtpUdpIp.headerBitsPerPacket;

  /// Fraction of the link audio may occupy; the rest is the control plane's
  /// survival margin (measured lesson, see library doc).
  static const double occupancyCeiling = 0.7;

  /// Codec-rate candidates, best first. 6 kbit/s is the intelligible-mono
  /// floor the ladder already ships (MediaProfile.lowRateVoice).
  static const List<int> rateCandidatesBps = [
    32000,
    24000,
    16000,
    12000,
    10000,
    8000,
    6000,
  ];

  /// Ptime candidates, lowest latency first. 20 ms is the Opus default;
  /// steps above 60 ms are survival steps for links where even the floor
  /// rate cannot otherwise fit under the ceiling.
  ///
  /// ONLY frame lengths the encoder actually supports. libwebrtc's Opus
  /// encoder offers {10, 20, 40, 60, 120} ms and quantizes a requested
  /// ptime DOWN to the nearest supported value — 80 and 100 are fictions
  /// that realize as 60 ms, which on a 16 kbit/s link turns a computed 70%
  /// occupancy into a real 83% and silently halves the control plane's
  /// survival margin. The realized ptime is what the wire sees; candidates
  /// the encoder cannot realize must not exist in the model.
  static const List<int> ptimeCandidatesMs = [20, 40, 60, 120];

  /// The configuration an unknown (unconstrained) link gets: the ladder's
  /// standard 32 kbit/s audio at the default 20 ms ptime, priced under the
  /// assumed (heavier) carrier because an unknown link has not reported
  /// its framing either.
  static const OpusWireBudget unconstrained = OpusWireBudget._(
    opusRateBps: 32000,
    ptimeMs: 20,
    bandwidthBps: null,
    carrier: WireCarrier.assumed,
  );

  /// Wire rate of a (rate, ptime) pair under [carrier], headers included.
  ///
  /// [carrier] defaults to [WireCarrier.assumed] — the heavier case — so an
  /// unannotated call cannot silently price itself optimistically.
  static int wireRateBps(
    int opusRateBps,
    int ptimeMs, {
    WireCarrier carrier = WireCarrier.assumed,
  }) => opusRateBps + (carrier.headerBitsPerPacket * 1000 / ptimeMs).round();

  /// Bits ONE frame of a (rate, ptime) pair puts on the wire under
  /// [carrier]: the payload a ptime-long frame carries at the candidate's
  /// rate (rate x ptime / 1000), plus the carrier's per-packet framing.
  /// This is the packet size a tick bound prices. Computed here, from the
  /// candidate's own constants, so no caller re-derives it and drifts
  /// from the model.
  static int frameBitsOnWire(
    int opusRateBps,
    int ptimeMs, {
    WireCarrier carrier = WireCarrier.assumed,
  }) => (opusRateBps * ptimeMs / 1000).round() + carrier.headerBitsPerPacket;

  /// This budget's own wire rate, under the carrier it was priced for.
  int get chosenWireRateBps =>
      wireRateBps(opusRateBps, ptimeMs, carrier: carrier);

  /// Fraction of the link this budget occupies (null on an unknown link).
  double? get occupancy =>
      bandwidthBps == null ? null : chosenWireRateBps / bandwidthBps!;

  /// Admission decision for a link of [bandwidthBps] (bits per second, per
  /// crossing) under [carrier] framing.
  ///
  /// Null or non-positive bandwidth means the link is unknown:
  /// [OpusWireUnconstrained] — not a refusal.
  ///
  /// Selection for [OpusWireFitted] is unchanged: the highest codec rate
  /// whose wire rate fits under [occupancyCeiling] x the per-stream share
  /// at ANY candidate ptime, carried at the SMALLEST such ptime.
  ///
  /// When no candidate fits, the answer is [OpusWireNoCandidateFits] —
  /// never a closest-anyway budget. The old fallback ("the model never
  /// refuses to place a call") survived only because the codec suppressed
  /// output during silence, keeping the real mean far below the nominal
  /// rate. Under a constant-rate requirement that valve is gone: the
  /// nominal rate IS the sustained rate, and offering more than the pipe
  /// carries means an unbounded queue and the death of BOTH directions.
  /// A link too narrow for the floor candidate is an ordinary condition,
  /// so it is reported as a value carrying the measured bandwidth, the
  /// per-stream budget, the cheapest candidate's wire rate, and the
  /// minimum bandwidth that would have been admitted.
  ///
  /// [concurrentStreams]: how many audio streams SHARE the given capacity.
  /// A two-party call is DUPLEX — both microphones cross the same shaped
  /// pipe (and under force-relay every stream crosses it twice), so the
  /// per-stream budget is the link's share divided by the streams on it.
  /// Measured 2026-08-08 (T2 narrow, 16 kbit/s per crossing): the
  /// single-stream arithmetic chose 8 kbit/s @ 120 ms = 10.7 kbit/s wire,
  /// four stream-crossings put ~133% of the physical pipe in flight, the
  /// queues starved liveness and the call died mid-transfer three runs in
  /// a row — while the identical row with NO local audio delivered clean.
  ///
  /// [carrier] defaults to [WireCarrier.assumed] (the heavier framing) so
  /// an admission run before the network layer has reported the carrier
  /// cannot silently over-subscribe the link.
  ///
  /// [tickProbe]: an optional bound the caller injects — for one concrete
  /// candidate, does a tick interval exist ([TickIntervalProbe])? Null
  /// (the default) means the bound is not consulted and behaviour is
  /// exactly the probe-less behaviour above, so this package stays usable
  /// standalone and every existing caller is unchanged. With the probe
  /// present, a candidate is admitted only if it fits under the ceiling
  /// AND the probe accepts it; the search order is unchanged (highest
  /// rate that qualifies at any candidate ptime, at the smallest such
  /// ptime). Cause attribution on refusal: if ANY candidate passed the
  /// ceiling check but was rejected by the probe, the refusal is
  /// [OpusWireRefusalCause.responsiveness] — the path is long, and no
  /// rate change answers that; if none did, it is
  /// [OpusWireRefusalCause.capacity]. The numeric fields of
  /// [OpusWireNoCandidateFits] keep their meaning in both cases.
  static OpusWireAdmission forBandwidth(
    int? bandwidthBps, {
    int concurrentStreams = 1,
    WireCarrier carrier = WireCarrier.assumed,
    TickIntervalProbe? tickProbe,
  }) {
    final bw = bandwidthBps;
    if (bw == null || bw <= 0) return const OpusWireUnconstrained();
    final streams = concurrentStreams < 1 ? 1 : concurrentStreams;
    final budget = occupancyCeiling * bw / streams;
    // Cause attribution: remember whether any candidate cleared the
    // ceiling and was then rejected by the probe. At least one did ->
    // the refusal is responsiveness; none did -> capacity.
    var probeRejectedFittingCandidate = false;
    for (final rate in rateCandidatesBps) {
      for (final ptime in ptimeCandidatesMs) {
        final wire = wireRateBps(rate, ptime, carrier: carrier);
        if (wire > budget) continue;
        if (tickProbe != null &&
            !tickProbe(
              wireRateBps: wire,
              perStreamBudgetBps: budget,
              frameBitsOnWire: frameBitsOnWire(rate, ptime, carrier: carrier),
            )) {
          probeRejectedFittingCandidate = true;
          continue;
        }
        return OpusWireFitted(
          OpusWireBudget._(
            opusRateBps: rate,
            ptimeMs: ptime,
            bandwidthBps: bw,
            carrier: carrier,
          ),
        );
      }
    }
    // No candidate fits. Compute the refusal's numbers from the same
    // constants the search used — an order-independent minimum, not a
    // positional assumption about the candidate lists.
    var cheapest = wireRateBps(
      rateCandidatesBps.first,
      ptimeCandidatesMs.first,
      carrier: carrier,
    );
    for (final rate in rateCandidatesBps) {
      for (final ptime in ptimeCandidatesMs) {
        final wire = wireRateBps(rate, ptime, carrier: carrier);
        if (wire < cheapest) cheapest = wire;
      }
    }
    // Smallest bandwidth whose per-stream share admits the cheapest
    // candidate. ceil() lands on the algebraic boundary; the loop absorbs
    // the floating-point edge so the reported minimum provably passes the
    // exact admission check quoted above.
    var minimumBps = (cheapest * streams / occupancyCeiling).ceil();
    while (occupancyCeiling * minimumBps / streams < cheapest) {
      minimumBps += 1;
    }
    return OpusWireNoCandidateFits(
      cause: probeRejectedFittingCandidate
          ? OpusWireRefusalCause.responsiveness
          : OpusWireRefusalCause.capacity,
      bandwidthBps: bw,
      perStreamBudgetBps: budget,
      cheapestWireRateBps: cheapest,
      // Null when the probe was the one that refused: no bandwidth makes a
      // tick interval exist on a path that long, so any figure here would
      // send the caller to buy capacity that changes nothing.
      minimumBandwidthBps: probeRejectedFittingCandidate ? null : minimumBps,
    );
  }

  /// Caps a ladder rung's audio bitrate to this budget: the ladder's shape
  /// (fast down, slow up) is untouched; its audio values become ceilings
  /// derived from the link instead of codec constants.
  int capAudioBitrate(int rungAudioBitrateBps) =>
      rungAudioBitrateBps < opusRateBps ? rungAudioBitrateBps : opusRateBps;

  @override
  String toString() =>
      'OpusWireBudget(opus ${opusRateBps}bps @ ${ptimeMs}ms, '
      'wire ${chosenWireRateBps}bps'
      '${bandwidthBps == null ? '' : ' on ${bandwidthBps}bps link '
                '(${(occupancy! * 100).toStringAsFixed(0)}%)'})';
}
