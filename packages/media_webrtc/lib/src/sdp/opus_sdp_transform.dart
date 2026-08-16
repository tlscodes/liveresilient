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

/// How the encoder treats silence. Exactly three states exist, and they are
/// one field rather than two booleans on purpose.
///
/// Discontinuous transmission and constant bitrate ask for opposite things:
/// DTX makes the output rate follow the content, constant bitrate makes it
/// not. Asking for both is incoherent. As two booleans that combination was
/// WRITABLE, and the only thing standing between it and an outgoing offer
/// was a runtime guard — first an `assert`, which release builds strip, then
/// a throw. As one field the impossible state cannot be expressed at all, so
/// the guard moves from run time to the compiler: it holds in every build,
/// with no path around it, and nothing has to remember to check.
enum OpusSilenceHandling {
  /// Neither knob is asked for; the stack's own behaviour stands.
  ///
  /// The shipped default. DTX is the single largest bandwidth saving
  /// available, but some middleboxes and some SFUs treat a silent flow as a
  /// dead flow and tear the call down, so it is enabled per network once
  /// there is field evidence — never globally by default.
  stackDefault,

  /// Send nothing during silence.
  discontinuous,

  /// Emit the same number of bits per frame regardless of content.
  ///
  /// Only admissible on a link measured to carry the nominal rate, because
  /// this removes the saving that keeps the narrowest links alive: the
  /// nominal rate becomes the sustained rate. See
  /// `OpusWireBudget.forBandwidth`, which refuses rather than downgrade.
  constant,
}

/// The knobs, with the defaults this project ships.
final class OpusSdpPolicy {
  const OpusSdpPolicy({
    this.inbandFec = true,
    this.silence = OpusSilenceHandling.stackDefault,
    this.maxAverageBitrateBps,
    this.ptimeMs,
  });

  /// In-band forward error correction. Costs bitrate exactly when the link is
  /// worst, and is still worth it: a lost packet is reconstructed from the next
  /// one instead of becoming a gap in speech.
  final bool inbandFec;

  /// How silence is handled. See [OpusSilenceHandling] for why this is one
  /// field and not two booleans.
  final OpusSilenceHandling silence;

  /// Initial ceiling only. Mid-call changes go through
  /// `RTCRtpSender.setParameters`, not through this function.
  final int? maxAverageBitrateBps;

  /// Packetization time in milliseconds. Larger means fewer packets and less
  /// header overhead, at the cost of latency. Null leaves whatever the stack chose.
  final int? ptimeMs;

  /// Discontinuous transmission is in force.
  bool get dtx => silence == OpusSilenceHandling.discontinuous;

  /// Constant bitrate is in force.
  bool get constantBitrate => silence == OpusSilenceHandling.constant;

  bool get isNoop =>
      !inbandFec &&
      silence == OpusSilenceHandling.stackDefault &&
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
    silence: fixedTickEmitterRunning
        ? OpusSilenceHandling.constant
        : OpusSilenceHandling.discontinuous,
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
  // Numeric validation lives HERE rather than in the constructor, and the
  // reason is the same one that turned the silence knobs into an enum: a
  // constructor that throws cannot be `const`, and a policy that cannot be
  // `const` cannot be a default parameter value. Checking at the point where
  // the numbers are written to the wire keeps the guard in every build —
  // including release, which is what an `assert` would not have done —
  // without taking constness away from the type.
  final rate = policy.maxAverageBitrateBps;
  if (rate != null && rate <= 0) {
    throw ArgumentError.value(
      rate,
      'maxAverageBitrateBps',
      'Must be positive: a non-positive ceiling is not a quieter stream, '
          'it is an offer no encoder can satisfy.',
    );
  }
  final ptime = policy.ptimeMs;
  if (ptime != null && ptime <= 0) {
    throw ArgumentError.value(
      ptime,
      'ptimeMs',
      'Must be positive: packetization time is a duration.',
    );
  }
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
