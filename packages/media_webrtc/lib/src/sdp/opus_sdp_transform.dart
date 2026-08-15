/// Opus knobs that only exist in SDP.
///
/// WHY THIS EXISTS. Three of the settings that matter most on a bad link —
/// in-band FEC, DTX, and the initial average-bitrate cap — have no API in
/// `flutter_webrtc`; they are expressible only as `a=fmtp` parameters. Codec
/// ORDERING belongs to `setCodecPreferences` and the ADAPTIVE bitrate belongs to
/// `RTCRtpSender.setParameters` — this file deliberately does neither, because
/// changing bitrate by re-munging would force a renegotiation mid-call.
///
/// It is a pure function over a string so it can be tested without a device, a
/// network, or the plugin. It is applied to OUR OWN descriptions — the offer or
/// answer this side creates and TRANSMITS — never to what the far end sent:
/// their description is what they want, and rewriting it is not ours to do.
/// The knobs are receive preferences (an encoder obeys the SDP it RECEIVED),
/// so they only act if they are inside the transmitted description; applying
/// them to the local copy alone reaches no encoder (measured 2026-08-06,
/// T2 `narrow`).
library;

/// The knobs, with the defaults this project ships.
final class OpusSdpPolicy {
  const OpusSdpPolicy({
    this.inbandFec = true,
    this.dtx = false,
    this.constantBitrate = false,
    this.maxAverageBitrateBps,
    this.ptimeMs,
  }) : assert(
         !(constantBitrate && dtx),
         'Constant bitrate and discontinuous transmission are mutually '
         'exclusive: suppressing output during silence is exactly what makes '
         'the output rate follow the content.',
       );

  /// In-band forward error correction. Costs bitrate exactly when the link is
  /// worst, and is still worth it: a lost packet is reconstructed from the next
  /// one instead of becoming a gap in speech.
  final bool inbandFec;

  /// Discontinuous transmission — send nothing during silence.
  ///
  /// Default OFF on purpose. It is the single largest bandwidth saving
  /// available, but some middleboxes and some SFUs treat a silent flow as a
  /// dead flow and tear the call down. It is enabled per-network behind a
  /// feature flag once there is field evidence, never globally by default.
  final bool dtx;

  /// Constant bitrate — the encoder emits the same number of bits per frame
  /// regardless of what the frame contains.
  ///
  /// Default OFF, and mutually exclusive with [dtx]: the two ask for opposite
  /// things. DTX makes the output rate follow the content, which is the
  /// single largest bandwidth saving available and the only reason the
  /// narrowest measured links survive today. Constant bitrate removes that
  /// saving, so the nominal rate becomes the sustained rate. It is therefore
  /// only admissible on a link that was measured to carry the nominal rate —
  /// see `OpusWireBudget.forBandwidth`, which refuses rather than downgrade.
  final bool constantBitrate;

  /// Initial ceiling only. Mid-call changes go through
  /// `RTCRtpSender.setParameters`, not through this function.
  final int? maxAverageBitrateBps;

  /// Packetization time in milliseconds. Larger means fewer packets and less
  /// header overhead, at the cost of latency. Null leaves whatever the stack chose.
  final int? ptimeMs;

  bool get isNoop =>
      !inbandFec &&
      !dtx &&
      !constantBitrate &&
      maxAverageBitrateBps == null &&
      ptimeMs == null;

  /// The policy for a link, with silence handling derived from whether the
  /// emitter is running its own clock (gate 1e).
  ///
  /// DTX and constant bitrate are not independent knobs to be set by hand:
  /// they are the two answers to the same question, and which one is correct
  /// follows from the shaping state. When a fixed-tick emitter is running,
  /// the output rate is already the tick's, so suppressing output during
  /// silence would only make the encoder's own rate content-dependent again
  /// underneath it — constant bitrate on, DTX off. When no emitter is
  /// running, DTX is the saving that keeps the narrow links alive, and
  /// constant bitrate would remove it for nothing.
  factory OpusSdpPolicy.forShapingState({
    required bool fixedTickEmitterRunning,
    int? maxAverageBitrateBps,
    int? ptimeMs,
    bool inbandFec = true,
  }) => OpusSdpPolicy(
    inbandFec: inbandFec,
    dtx: !fixedTickEmitterRunning,
    constantBitrate: fixedTickEmitterRunning,
    maxAverageBitrateBps: maxAverageBitrateBps,
    ptimeMs: ptimeMs,
  );
}

/// Applies [policy] to the Opus `a=fmtp` line of [sdp].
///
/// The payload type is read from the `a=rtpmap` line rather than assumed to be
/// 111: it is a DYNAMIC payload type and it differs between platforms, so a
/// hardcoded number silently edits the wrong codec.
///
/// The rewrite is key-by-key, so applying it twice yields the same string —
/// which matters because renegotiation and ICE restart run it again.
String applyOpusPolicy(String sdp, OpusSdpPolicy policy) {
  if (sdp.isEmpty) return sdp;

  final crlf = sdp.contains('\r\n');
  final eol = crlf ? '\r\n' : '\n';
  final lines = sdp.split(crlf ? '\r\n' : '\n');

  // Locate the audio media section. Everything outside it must come back byte
  // for byte — the BUNDLE group, rtcp-mux, and every other m-line included.
  var audioStart = -1;
  var audioEnd = lines.length;
  for (var i = 0; i < lines.length; i++) {
    if (lines[i].startsWith('m=')) {
      if (audioStart >= 0) {
        audioEnd = i;
        break;
      }
      if (lines[i].startsWith('m=audio ')) audioStart = i;
    }
  }
  if (audioStart < 0) return sdp;

  // The Opus payload type, from the rtpmap line inside this section only.
  String? opusPt;
  for (var i = audioStart; i < audioEnd; i++) {
    final m = RegExp(r'^a=rtpmap:(\d+)\s+opus/48000(/2)?\s*$', caseSensitive: false)
        .firstMatch(lines[i].trim());
    if (m != null) {
      opusPt = m.group(1);
      break;
    }
  }
  if (opusPt == null) return sdp;

  final wanted = <String, String>{
    if (policy.inbandFec) 'useinbandfec': '1',
    if (policy.dtx) 'usedtx': '1',
    if (policy.constantBitrate) 'cbr': '1',
    if (policy.maxAverageBitrateBps != null)
      'maxaveragebitrate': '${policy.maxAverageBitrateBps}',
  };

  final out = <String>[];
  var fmtpSeen = false;
  var ptimeSeen = false;
  var maxPtimeSeen = false;
  var rtpmapIndex = -1;

  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    final inAudio = i >= audioStart && i < audioEnd;

    if (inAudio && line.startsWith('a=rtpmap:$opusPt ')) {
      rtpmapIndex = out.length;
      out.add(line);
      continue;
    }

    if (inAudio && line.startsWith('a=fmtp:$opusPt ')) {
      fmtpSeen = true;
      out.add('a=fmtp:$opusPt ${_mergeParams(line.substring('a=fmtp:$opusPt '.length), wanted)}');
      continue;
    }

    if (inAudio && policy.ptimeMs != null && line.startsWith('a=ptime:')) {
      ptimeSeen = true;
      out.add('a=ptime:${policy.ptimeMs}');
      continue;
    }

    // maxptime travels with ptime: without it a peer's default maxptime
    // (commonly 60) silently caps a 120 ms request back to 60 and the wire
    // model's occupancy math stops describing the wire.
    if (inAudio && policy.ptimeMs != null && line.startsWith('a=maxptime:')) {
      maxPtimeSeen = true;
      out.add('a=maxptime:${policy.ptimeMs}');
      continue;
    }

    out.add(line);
  }

  // Insert what was missing, directly after the rtpmap line so the section stays
  // in the conventional order.
  final inserts = <String>[
    if (!fmtpSeen && wanted.isNotEmpty)
      'a=fmtp:$opusPt ${_mergeParams('', wanted)}',
    if (!ptimeSeen && policy.ptimeMs != null) 'a=ptime:${policy.ptimeMs}',
    if (!maxPtimeSeen && policy.ptimeMs != null)
      'a=maxptime:${policy.ptimeMs}',
  ];
  if (inserts.isNotEmpty && rtpmapIndex >= 0) {
    out.insertAll(rtpmapIndex + 1, inserts);
  }

  return out.join(eol);
}

/// Overwrites the keys in [wanted] and preserves every other key in order —
/// this is what makes a second application a no-op.
String _mergeParams(String existing, Map<String, String> wanted) {
  final params = <String, String?>{};
  for (final part in existing.split(';')) {
    final t = part.trim();
    if (t.isEmpty) continue;
    final eq = t.indexOf('=');
    if (eq < 0) {
      params[t] = null;
    } else {
      params[t.substring(0, eq)] = t.substring(eq + 1);
    }
  }
  params.addAll(wanted);
  return params.entries
      .map((e) => e.value == null ? e.key : '${e.key}=${e.value}')
      .join(';');
}
