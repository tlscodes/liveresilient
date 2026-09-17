/// The phone side of the app journey as a PERSISTENT peer.
///
/// Installed once, launched per profile, never reinstalled — so the
/// microphone prompt is answered once and every profile row carries real
/// audio (a replaced install re-asks, measured 2026-09-03: normal and
/// extreme ran without phone audio for that reason alone). It is a plain
/// Flutter app, not a test: nothing attaches to it, so its evidence travels
/// over the rig's plain-HTTP hub instead of a test log.
///
/// Loop: pre-warm the microphone (the one prompt) → GET /job → build a real
/// call stack (initiator) with the shared lane table → report `stack_up` →
/// wait for /go → place the call → receive chat text, chunked attachments
/// (voice notes, files), staged photos and video notes on their lanes,
/// POSTing one event per item with its sha256 and the item's raw bytes to
/// /blob (so the Mac can decode what the phone received) → hold until the
/// app hangs up (or the job's hold expires) → drain the blob posts →
/// report `ended` → loop.
///
/// Defines:
///   E2E_RELAY_URI         wss://192.168.2.1:4443/  (the Mac's bridge address)
///   JOURNEY_HUB_URL       http://192.168.2.1:8765  (tools/t2/journey_hub.py)
///   E2E_CONNECT_BUDGET_S  connect + reconnect budget in seconds (300)
library;

// Evidence lines are also printed for a tethered `flutter run`.
// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:adaptive_transport/adaptive_transport.dart'
    show
        HostPort,
        HttpLongPollLane,
        TxtQueryLane,
        TxtQueryWire,
        TxtQueryValve,
        WebSocketRelayLane;
import 'package:call_core/call_core.dart';
import 'package:connection_orchestrator/connection_orchestrator.dart'
    show ConnectionFabric, ResilientFallbackLanes, ResilientLaneIds;
import 'package:cryptography/cryptography.dart';
import 'package:device_link/device_link.dart'
    show BundleAdmission, DtnBundle, DtnBundleQueue, LinkMessagePriority;
import 'package:device_link/durable_store.dart' show DurableBundleStore;
import 'package:flutter/material.dart';
import 'package:media_webrtc/media_webrtc.dart' show RawRtcCounters;
import 'package:media_webrtc_flutter/media_webrtc_flutter.dart'
    show SelectedIcePair;
import 'package:messaging/messaging.dart';
import 'package:messaging_webrtc_adapter/messaging_webrtc_adapter.dart';
import 'package:reference_app/src/voice_letter_recorder.dart';
import 'package:reference_app/src/call_session.dart'
    show defaultBorderRelayEndpoints, parseValveResolvers;
import 'package:wakelock_plus/wakelock_plus.dart';

import 'blackout_forwarder.dart';
import 'blackout_stream.dart';
import 'support/e2e_support.dart';
import 'whitelist_door.dart';

const String journeyHubUrl = String.fromEnvironment(
  'JOURNEY_HUB_URL',
  defaultValue: 'http://192.168.2.1:8765',
);
const int journeyConnectBudgetS = int.fromEnvironment(
  'E2E_CONNECT_BUDGET_S',
  defaultValue: 300,
);

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final peer = JourneyPeer();
  runApp(JourneyPeerApp(peer));
  unawaited(peer.run());
}

/// One job handed out by the hub: which key to call, how long to hold.
class JourneyJob {
  final String run;
  final String key;
  final int holdS;

  /// Present for the blackout profile: v1 {bytes, probe_s, lifetime_s}, or
  /// v2 {v:2, plan:[{kind,bytes,n}...], probe_s, lifetime_s, chunk_bytes}
  /// (see BlackoutPlan). The peer then holds signed bundles instead of
  /// placing a call.
  final Map<String, Object?>? blackout;

  /// Present for the whitelist profile: {url, interval_s, blocked_host,
  /// rst_port, quic_port, quic_timeout_ms, relay_only} (see
  /// [WhitelistDoorConfig]). The peer then runs the ordinary-traffic loop
  /// and the two negative controls BESIDE the normal call — never instead
  /// of it.
  final Map<String, Object?>? whitelist;

  /// Present for the dnsvalve profile: {zone, resolvers:["host:port",...],
  /// chat_bytes, select_budget_s, carry_budget_s, relay_only} (see
  /// [DnsValveConfig]). The peer then builds its OWN [ConnectionFabric] and
  /// carries one message over the DNS valve lane BESIDE the normal call —
  /// never instead of it, unlike [blackout], which replaces the call.
  ///
  /// The zone and resolvers come from the job, not from this build's
  /// `DNS_VALVE_*` defines: the peer's call path never constructs a fabric,
  /// so those defines carry no lane on their own and the rig must be able
  /// to re-aim the valve without a reinstall.
  final Map<String, Object?>? dnsValve;

  const JourneyJob({
    required this.run,
    required this.key,
    required this.holdS,
    this.blackout,
    this.whitelist,
    this.dnsValve,
  });

  static JourneyJob? tryParse(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map<String, Object?>) return null;
      final run = decoded['run'];
      final key = decoded['key'];
      final hold = decoded['hold_s'];
      if (run is! String || key is! String || run.isEmpty || key.isEmpty) {
        return null;
      }
      final blackout = decoded['blackout'];
      final whitelist = decoded['whitelist'];
      final dnsValve = decoded['dns_valve'];
      return JourneyJob(
        run: run,
        key: key,
        holdS: hold is int ? hold : 400,
        blackout: blackout is Map<String, Object?> ? blackout : null,
        whitelist: whitelist is Map<String, Object?> ? whitelist : null,
        dnsValve: dnsValve is Map<String, Object?> ? dnsValve : null,
      );
    } on FormatException {
      return null;
    }
  }
}

/// The dnsvalve profile's job config: which zone the responder answers for,
/// which resolvers to pin it to, how big the proof message is, and how long
/// each of the branch's two phases may take.
///
/// Parsed at arm time for the same reason [BlackoutPlan] is: a job whose
/// zone is missing, or whose message is bigger than the lane can carry,
/// has no row to produce, and a run that discovered that only after a rig
/// minute was spent would read like a lane failure instead of a bad job.
class DnsValveConfig {
  const DnsValveConfig({
    required this.zone,
    required this.resolvers,
    required this.chatBytes,
    required this.selectBudget,
    required this.carryBudget,
    required this.relayOnly,
    this.chatText,
    this.chatSource = 'mac',
    this.phoneWait = Duration.zero,
  });

  /// Zone the authoritative responder answers for, e.g. `valve.example`.
  final String zone;

  /// Resolvers the valve is pinned to. Empty means "walk this device's own
  /// candidates", which on the rig would miss the Mac's responder.
  final List<HostPort> resolvers;

  /// Size of the one payload the branch carries.
  final int chatBytes;

  /// The exact bytes to carry, when the job names them (`chat_text_b64`).
  ///
  /// Filler derived from the run id proves carriage but says nothing about
  /// what a person would actually send, and a message worth sending when the
  /// ordinary path is shut is a short letter, not a pattern. The Mac holds the
  /// file, so it can still recompute the digest the responder must log without
  /// the phone telling it what it sent. Null keeps the derived payload.
  final Uint8List? chatText;

  /// Who writes the letter: `mac` (the job carries it, or filler is derived)
  /// or `phone` — the bytes are what the person typed on the phone screen
  /// (`JourneyPeer.draft`), which the Mac cannot know in advance, so the row
  /// then rests on two witnesses (the phone's digest and the responder's)
  /// instead of three. `chat_bytes` is unused for a phone letter; the honest
  /// length is what the lane_chat event reports.
  final String chatSource;

  /// How long a phone letter (`chatSource == 'phone'`) waits for the person
  /// to type and tap Send before falling back to the draft-or-default choice.
  /// Zero means today's behavior: read `draft` immediately, no window.
  /// Capped at parse time (120 s) so this wait plus [selectBudget] plus
  /// [carryBudget] can never exceed the Mac app's own 300 s connect budget.
  final Duration phoneWait;

  /// How long the refresh loop may wait for the valve to rank first.
  final Duration selectBudget;

  /// How long the single delivery may take once the loop has settled.
  final Duration carryBudget;

  /// True when the rig's filter drops every UDP port but the valve's, so
  /// the call must not attempt a UDP TURN allocation at all.
  final bool relayOnly;

  /// The whole branch's wall-clock budget: the two phases run in sequence.
  Duration get totalBudget => selectBudget + carryBudget;

  /// Throws [FormatException] on anything that cannot produce a row.
  static DnsValveConfig parse(Map<String, Object?> json) {
    final zone = (json['zone'] ?? '').toString().trim();
    if (zone.isEmpty) {
      throw const FormatException('dns_valve.zone is empty');
    }
    final raw = json['resolvers'];
    final spec = raw is List
        ? raw.map((entry) => '$entry').join(',')
        : (raw ?? '').toString();
    // Same parser the app's own build-time define uses, so a rig job and a
    // compiled build cannot disagree about what `host:port` means.
    final resolvers = parseValveResolvers(spec);
    final chatBytes = _positiveInt(json['chat_bytes'], 64, 'chat_bytes');
    if (chatBytes > TxtQueryLane.maxPayloadBytes) {
      throw FormatException(
        'dns_valve.chat_bytes $chatBytes exceeds the lane limit '
        '${TxtQueryLane.maxPayloadBytes}',
      );
    }
    // A job that names both a text and a byte count must agree with itself:
    // the row prints chat_bytes, and a disagreement would make the row
    // describe a payload the phone never sent.
    final Uint8List? chatText;
    final rawText = json['chat_text_b64'];
    if (rawText == null) {
      chatText = null;
    } else {
      final Uint8List decoded;
      try {
        decoded = base64.decode('$rawText');
      } on FormatException catch (error) {
        throw FormatException('dns_valve.chat_text_b64 is not base64: $error');
      }
      if (decoded.length != chatBytes) {
        throw FormatException(
          'dns_valve.chat_text_b64 decodes to ${decoded.length} bytes, '
          'but chat_bytes says $chatBytes',
        );
      }
      chatText = decoded;
    }
    final chatSource = '${json['chat_source'] ?? 'mac'}';
    if (chatSource != 'mac' && chatSource != 'phone') {
      throw FormatException(
        'dns_valve.chat_source "$chatSource" is neither mac nor phone',
      );
    }
    // Two authors for one letter is a job that contradicts itself.
    if (chatSource == 'phone' && chatText != null) {
      throw const FormatException(
        'dns_valve.chat_source is phone but chat_text_b64 names a letter',
      );
    }
    final phoneWaitS = _nonNegativeInt(json['phone_wait_s'], 0, 'phone_wait_s');
    if (phoneWaitS > 120) {
      throw FormatException(
        'dns_valve.phone_wait_s $phoneWaitS exceeds the 120 s cap (it would '
        'eat into the select/carry budget or the Mac app\'s 300 s connect '
        'budget)',
      );
    }
    return DnsValveConfig(
      zone: zone,
      resolvers: resolvers,
      chatBytes: chatBytes,
      selectBudget: Duration(
        seconds: _positiveInt(json['select_budget_s'], 120, 'select_budget_s'),
      ),
      carryBudget: Duration(
        seconds: _positiveInt(json['carry_budget_s'], 120, 'carry_budget_s'),
      ),
      relayOnly: json['relay_only'] == true,
      chatText: chatText,
      chatSource: chatSource,
      phoneWait: Duration(seconds: phoneWaitS),
    );
  }

  static int _positiveInt(Object? value, int fallback, String field) {
    if (value == null) return fallback;
    final parsed = value is num ? value.toInt() : int.tryParse('$value');
    if (parsed == null || parsed < 1) {
      throw FormatException('dns_valve.$field "$value" is not a positive int');
    }
    return parsed;
  }

  static int _nonNegativeInt(Object? value, int fallback, String field) {
    if (value == null) return fallback;
    final parsed = value is num ? value.toInt() : int.tryParse('$value');
    if (parsed == null || parsed < 0) {
      throw FormatException(
        'dns_valve.$field "$value" is not a non-negative int',
      );
    }
    return parsed;
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'zone': zone,
    'resolvers': [for (final r in resolvers) '${r.host}:${r.port}'],
    'chat_bytes': chatBytes,
    'select_budget_s': selectBudget.inSeconds,
    'carry_budget_s': carryBudget.inSeconds,
    'relay_only': relayOnly,
    if (chatText != null) 'chat_text_b64': base64.encode(chatText!),
    'chat_source': chatSource,
    'phone_wait_s': phoneWait.inSeconds,
  };
}

/// The dnsvalve branch's payload: exactly [bytes] bytes, derived from
/// [run] alone.
///
/// Deterministic on purpose. The Mac handed out the run id, so it can
/// recompute these bytes and their sha256 without the phone telling it
/// what it sent — which is what makes a matching sha256 in the responder's
/// log evidence of carriage rather than a receipt the sender wrote itself.
Uint8List dnsValvePayload(String run, int bytes) {
  final header = utf8.encode('dns-valve $run ');
  final out = Uint8List(bytes);
  for (var i = 0; i < bytes; i++) {
    out[i] = header[i % header.length];
  }
  return out;
}

/// How many TXT queries the lane needs for a payload of [payloadBytes].
///
/// The wire frames the payload behind [TxtQueryWire.frameHeader] bytes and
/// splits the frame [TxtQueryWire.rawPerLabel] bytes per label: 200 bytes
/// are 6 round trips, 1022 are 27, the lane's 4096-byte limit is 106. The
/// lane keeps no chunk total of its own, so the screen derives it from the
/// exported split — the same code the sender runs — never from a copy of
/// the constants, which would drift.
int txtChunkCount(int payloadBytes) => TxtQueryWire.splitChunks(
  TxtQueryWire.frameUp(Uint8List(payloadBytes)),
).length;

/// The letter a phone sends when the person typed nothing: honest about its
/// origin and its run, short enough to cost a handful of queries.
String phoneDefaultLetter(String run) =>
    'from the phone, run $run: the ordinary path is shut, this went out '
    'the DNS door.';

/// What the screen shows for a carried payload: the text when it IS text,
/// a description when it is not. Strict decoding on purpose — a lenient
/// decode would print a binary payload as garbage and a person would read
/// that as a corrupted letter.
String describeLetter(Uint8List payload, String sha256) {
  try {
    return utf8.decode(payload);
  } on FormatException {
    return '<binary, ${payload.length} B, sha256 ${sha256.substring(0, 16)}>';
  }
}

/// A reply older than this is not "alive": the lane's per-chunk budget is
/// about 10 s on the phone (chunkBudget) and a pacing wait follows a fast
/// negative, so a chunk that legally retried and rotated resolvers goes
/// quiet for up to ~14 s while still in flight. 15 s is that, rounded.
const Duration doorQuiet = Duration(seconds: 15);

/// Queries per landed chunk above which the open door is called slow: every
/// chunk costing more than one and a half queries means retries, not pace.
const double doorSlowRetries = 1.5;

/// One honest line for the phone screen while the letter is on the valve.
///
/// The words are the person's, the inputs are the lane's counters since the
/// send began. "alive" appears only when a reply landed within [doorQuiet];
/// a valve that last answered a minute ago is not alive, it is unknown, and
/// the line says so. Only [down] closes the door — a low score is a weak
/// path, not a shut one.
String doorLine({
  required bool down,
  required int attempts,
  required int landed,
  required int total,
  required Duration? sinceReply,
}) {
  final chunks = 'chunks $landed/$total';
  if (down) return 'door closed · lane down · $chunks';
  if (sinceReply == null) {
    return 'door unproven · no reply yet · attempts $attempts · $chunks';
  }
  final ago = '${sinceReply.inSeconds}s ago';
  if (sinceReply > doorQuiet) return 'door open? · quiet $ago · $chunks';
  final retries = attempts / (landed < 1 ? 1 : landed);
  final pace = retries > doorSlowRetries ? 'slow · alive' : 'alive';
  return 'door open · $pace · $chunks · reply $ago';
}

/// The Record button's whole truth. One value, rendered by one button, so
/// idle and recording can never look alike.
enum VoiceRecordState {
  /// Nothing captured yet, or the last take was refused.
  idle,

  /// The microphone is opening (a platform round-trip, and on a fresh
  /// install a permission prompt) — taps are joined, not dropped.
  starting,

  /// Capturing. The button shows the elapsed counter against the cap.
  recording,

  /// Stopped; encoding to Codec2 700C.
  stopping,

  /// A letter is in hand, waiting for Send.
  recorded,
}

/// Something the person holding the phone must see and dismiss by hand.
class VoiceAlert {
  const VoiceAlert(this.message, {this.isError = true});

  final String message;

  /// False for the cap notice, which reports a success.
  final bool isError;
}

/// The plain-words reason a recording produced no letter. Each refusal says
/// what to do differently; the old single line ("too short or off-rate")
/// could not tell a half-second tap from a plugin delivering the wrong
/// sample rate.
String voiceRefusalText(VoiceRecording recorder) {
  switch (recorder.refusal) {
    case VoiceLetterRefusal.tooShort:
      return 'Too short — only ${recorder.elapsed.inMilliseconds} ms was '
          'captured. Tap Record, speak for at least a few seconds, then tap '
          'Stop.';
    case VoiceLetterRefusal.offRate:
      return 'The microphone delivered ${recorder.pcmBytes} bytes for '
          '${recorder.elapsed.inSeconds}s, not the '
          '${recorder.elapsed.inMilliseconds * 16} expected. The recording '
          'was refused rather than carried as noise.';
    case VoiceLetterRefusal.failed:
      return 'The recording failed: ${recorder.stopError}';
    case VoiceLetterRefusal.notStarted:
    case null:
      return 'The recording never started — nothing was captured.';
  }
}

/// `m:ss`, for the counter on a recording button.
String voiceClock(Duration value) {
  final seconds = value.inSeconds < 0 ? 0 : value.inSeconds;
  return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
}

/// What the Record button says in each state. A first-time user reads only
/// this, so every state names itself and the live one carries its counter.
String voiceRecordButtonLabel(VoiceRecordState state, Duration elapsed) {
  switch (state) {
    case VoiceRecordState.idle:
      return 'Record (≤30s)';
    case VoiceRecordState.starting:
      return 'Opening microphone…';
    case VoiceRecordState.recording:
      return 'STOP • ${voiceClock(elapsed)} / '
          '${voiceClock(voiceLetterMaxLength)}';
    case VoiceRecordState.stopping:
      return 'Encoding…';
    case VoiceRecordState.recorded:
      return 'Recorded ${voiceClock(elapsed)} — tap to redo';
  }
}

class JourneyPeer {
  final ValueNotifier<String> status = ValueNotifier<String>('booting');
  final ValueNotifier<List<String>> events = ValueNotifier<List<String>>([]);

  /// The letter as handed to the DNS valve lane, for the person holding the
  /// phone. The event list carries digests and counters, which prove the
  /// carriage to the Mac and say nothing to a reader; this is the text.
  /// Empty until a job names a letter; synthetic filler is described, not
  /// printed.
  final ValueNotifier<String> letter = ValueNotifier<String>('');

  /// What the person typed on the phone screen; carried verbatim when the
  /// job says `chat_source: phone`. Never cleared by a job, so a draft typed
  /// before the run is the one that goes.
  final ValueNotifier<String> draft = ValueNotifier<String>('');

  /// True while a phone letter's Send window is open (chatSource=phone,
  /// phoneWait > 0): the person has a real chance to type before the
  /// automatic choice fires. False the rest of the time, including every
  /// unattended run (phoneWait == Duration.zero never opens it).
  final ValueNotifier<bool> letterWanted = ValueNotifier<bool>(false);
  Completer<void>? _letterGate;

  /// Ends the Send window early. A no-op once the gate has already
  /// resolved (submit or timeout), so a stray double-tap cannot throw.
  void submitLetter() {
    final gate = _letterGate;
    if (gate != null && !gate.isCompleted) gate.complete();
  }

  /// A voice letter recorded during the current Send window, if any.
  /// Takes priority over `draft` when non-null; cleared once the letter
  /// is built so a stale recording never rides the next job.
  final ValueNotifier<VoiceLetter?> voiceLetter = ValueNotifier<VoiceLetter?>(
    null,
  );

  /// What the Record button is doing right now. The button renders this and
  /// nothing else, so there is exactly one answer on screen to "is it
  /// recording?" — the old button read `voiceLetter`, which is null both
  /// before a recording and during one, so idle and recording looked
  /// identical to the person holding the phone.
  final ValueNotifier<VoiceRecordState> recordState =
      ValueNotifier<VoiceRecordState>(VoiceRecordState.idle);

  /// How long the live recording has run. Ticks while
  /// [VoiceRecordState.recording], frozen at the final length afterwards.
  final ValueNotifier<Duration> recordElapsed = ValueNotifier<Duration>(
    Duration.zero,
  );

  /// A message the person must see and dismiss by hand: a recording that
  /// failed or was refused, or the 30 s cap closing one on its own. The
  /// event list below is a 40-line scrolling log of lane counters — a
  /// failure written only there is, in practice, invisible mid-task, which
  /// is exactly how a 120 s window was spent with nothing captured and
  /// nothing on screen to say so.
  final ValueNotifier<VoiceAlert?> voiceAlert = ValueNotifier<VoiceAlert?>(
    null,
  );

  /// Clears the banner. Only a tap does this — no timeout, no next event.
  void dismissVoiceAlert() => voiceAlert.value = null;

  /// Builds the recording this peer drives. Overridden in tests, which have
  /// no microphone; production is always [VoiceLetterRecorder].
  @visibleForTesting
  VoiceRecording Function() newRecording = VoiceLetterRecorder.new;

  VoiceRecording? _recorder;
  Future<void>? _transition;
  Timer? _recordTicker;

  /// Starts recording on the first tap, stops and encodes on the second.
  /// Any failure (permission denied, rate guard, codec error) is caught
  /// here and only disables voice for this window — the typed-text path
  /// is never touched by a voice failure.
  ///
  /// A tap that lands while a start or a stop is still in flight JOINS that
  /// transition instead of beginning another one. It used to begin another
  /// one: `_recorder` was assigned only after `start()` resolved, so a
  /// second tap during the platform's microphone-open round-trip opened a
  /// second [AudioRecorder] and orphaned the first with the microphone
  /// held.
  Future<void> toggleRecording() {
    final live = _transition;
    if (live != null) return live;
    final work = _transition = _toggle().whenComplete(() => _transition = null);
    return work;
  }

  Future<void> _toggle() async {
    final live = _recorder;
    if (live == null) return _startRecording();
    return _finishRecording(live);
  }

  Future<void> _startRecording() async {
    recordState.value = VoiceRecordState.starting;
    voiceAlert.value = null;
    voiceLetter.value = null;
    recordElapsed.value = Duration.zero;
    final recorder = newRecording();
    recorder.onCapReached = (letter, refusal) => _capReached(recorder, letter);
    try {
      await recorder.start();
    } on Object catch (error) {
      recordState.value = VoiceRecordState.idle;
      _voiceFailed('The microphone did not open. $error');
      return;
    }
    _recorder = recorder;
    recordState.value = VoiceRecordState.recording;
    _recordTicker = Timer.periodic(
      const Duration(milliseconds: 200),
      (_) => recordElapsed.value = recorder.elapsed,
    );
    _note('voice recording started, cap ${voiceLetterMaxLength.inSeconds}s');
  }

  Future<void> _finishRecording(VoiceRecording live) async {
    recordState.value = VoiceRecordState.stopping;
    _recorder = null;
    _stopTicker();
    _settle(live, await live.stop(), capped: false);
  }

  void _capReached(VoiceRecording recorder, VoiceLetter? letter) {
    // A tap already finished this one; its own `stop()` returns the same
    // letter, so there is nothing left to settle here.
    if (!identical(_recorder, recorder)) return;
    _recorder = null;
    _stopTicker();
    _settle(recorder, letter, capped: true);
  }

  void _stopTicker() {
    _recordTicker?.cancel();
    _recordTicker = null;
  }

  void _settle(
    VoiceRecording recorder,
    VoiceLetter? letter, {
    required bool capped,
  }) {
    recordElapsed.value = recorder.elapsed;
    voiceLetter.value = letter;
    if (letter == null) {
      recordState.value = VoiceRecordState.idle;
      _voiceFailed(voiceRefusalText(recorder));
      return;
    }
    recordState.value = VoiceRecordState.recorded;
    _note(
      'voice recorded ${letter.length.inSeconds}s '
      '${letter.wire.length}B frames=${letter.frames} capped=$capped',
    );
    if (capped) {
      voiceAlert.value = VoiceAlert(
        'Maximum ${voiceLetterMaxLength.inSeconds}s reached. The recording '
        'is saved (${letter.length.inSeconds}s) — tap Send letter to carry '
        'it.',
        isError: false,
      );
    }
  }

  void _voiceFailed(String message) {
    voiceAlert.value = VoiceAlert(message);
    _note('voice failed: $message');
  }

  /// Finalizes a recording that is still running and waits out one already
  /// being encoded, without ever starting a new one. The Send window calls
  /// this before it reads [voiceLetter]: a Stop tap at the very end of the
  /// window would otherwise still be encoding when the letter is read, and
  /// the take would be dropped for a default letter.
  Future<void> finalizeRecording() async {
    final live = _transition;
    if (live != null) await live;
    if (_recorder != null) await toggleRecording();
  }

  final HttpClient _http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 3);

  /// Bundle bodies ride a separate client: on a 16 kbit/s gate one 8 KB
  /// chunk is about 4 s of wire time, so its connect and reply deadlines
  /// are far longer than the probe's; a shared client would let the
  /// probe's 3 s connect timeout cut every chunk short.
  final HttpClient _bulkHttp = HttpClient()
    ..connectionTimeout = const Duration(seconds: 10);

  MediaMode? _mode;
  String? _lastRun;

  /// This install's Ed25519 key pair, made at boot; the public key rides
  /// the boot event so the Mac can verify a bundle signed hours later.
  SimpleKeyPair? _keyPair;
  String? _pubkeyB64;

  void _note(String line) {
    final stamped =
        '${DateTime.now().toIso8601String().substring(11, 19)} $line';
    print('JOURNEY_PEER $line');
    final next = List<String>.of(events.value)..add(stamped);
    if (next.length > 40) next.removeRange(0, next.length - 40);
    events.value = next;
  }

  Future<void> run() async {
    // The one microphone prompt: asked here, at launch, so the operator can
    // answer it while the Mac side is still building, and never again for
    // the life of this install.
    _mode = await resolveMediaMode();
    // A blackout job holds the phone for hours with no call to keep it
    // awake; without this the screen locks and iOS suspends the prober.
    try {
      await WakelockPlus.enable();
    } on Object catch (error) {
      _note('wakelock unavailable: $error');
    }
    final keyPair = _keyPair = await Ed25519().newKeyPair();
    _pubkeyB64 = base64Encode((await keyPair.extractPublicKey()).bytes);
    _note('boot media=${_mode!.name} hub=$journeyHubUrl');
    // `blob: true` tells the runner this install posts media bytes to /blob;
    // an older install reports only sha256 receipts. `blackout: true` says
    // it can hold a signed bundle across an outage, and `pubkey` is the
    // Ed25519 public key the Mac verifies that bundle against.
    await _report('boot', <String, Object?>{
      'media': _mode!.name,
      'blob': true,
      'blackout': true,
      'pubkey': _pubkeyB64,
    });
    while (true) {
      final job = await _nextJob();
      if (job == null) {
        status.value = 'waiting for a job (${_mode!.name})';
        await Future<void>.delayed(const Duration(seconds: 1));
        continue;
      }
      _lastRun = job.run;
      await _serve(job);
    }
  }

  Future<JourneyJob?> _nextJob() async {
    try {
      final response = await _http
          .getUrl(Uri.parse('$journeyHubUrl/job'))
          .then((request) => request.close())
          .timeout(const Duration(seconds: 5));
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode != 200) return null;
      final job = JourneyJob.tryParse(body);
      if (job == null || job.run == _lastRun) return null;
      return job;
    } on Object {
      return null;
    }
  }

  Future<bool> _goRaised(String run) async {
    try {
      final response = await _http
          .getUrl(Uri.parse('$journeyHubUrl/go/$run'))
          .then((request) => request.close())
          .timeout(const Duration(seconds: 5));
      await response.drain<void>();
      return response.statusCode == 200;
    } on Object {
      return false;
    }
  }

  /// One JSON line per event to the hub; best effort, never throws — the
  /// call must not depend on the evidence channel.
  Future<void> _report(
    String event,
    Map<String, Object?> fields, {
    String? run,
  }) async {
    final body = jsonEncode(<String, Object?>{
      'event': event,
      'run': run ?? _lastRun,
      'at': DateTime.now().toUtc().toIso8601String(),
      ...fields,
    });
    try {
      final request = await _http
          .postUrl(Uri.parse('$journeyHubUrl/report'))
          .timeout(const Duration(seconds: 5));
      request.headers.contentType = ContentType.json;
      request.write(body);
      final response = await request.close().timeout(
        const Duration(seconds: 5),
      );
      await response.drain<void>();
    } on Object catch (error) {
      print('JOURNEY_PEER report failed event=$event error=$error');
    }
  }

  /// The raw bytes of one received media item to the hub's /blob route, so
  /// the Mac can decode what the phone received instead of trusting a
  /// sha256 receipt alone. Best effort, never throws: one try, then up to
  /// three retries 1 s, 2 s, 4 s apart; true once the hub answered 200.
  ///
  /// The body goes through contentLength + add(bytes): `write` would send
  /// the bytes as chunked text, and the hub compares the sha of exactly
  /// what arrived against the query's sha256.
  Future<bool> _postBlob({
    required String run,
    required String kind,
    required String id,
    required List<int> bytes,
  }) async {
    final sha = contentSha256Hex(bytes);
    final url = Uri.parse(
      '$journeyHubUrl/blob'
      '?run=${Uri.encodeQueryComponent(run)}'
      '&kind=${Uri.encodeQueryComponent(kind)}'
      '&id=${Uri.encodeQueryComponent(id)}'
      '&sha256=${Uri.encodeQueryComponent(sha)}',
    );
    // One try, then up to three retries with these delays between them.
    const delays = [
      Duration(seconds: 1),
      Duration(seconds: 2),
      Duration(seconds: 4),
    ];
    for (var attempt = 0; attempt <= delays.length; attempt++) {
      var code = 0;
      try {
        final request = await _http
            .postUrl(url)
            .timeout(const Duration(seconds: 5));
        request.headers.contentType = ContentType.binary;
        request.contentLength = bytes.length;
        request.add(bytes);
        final response = await request.close().timeout(
          const Duration(seconds: 15),
        );
        code = response.statusCode;
        await response.drain<void>();
      } on Object catch (error) {
        _note('blob kind=$kind id=$id bytes=${bytes.length} error=$error');
      }
      _note(
        'blob kind=$kind id=$id bytes=${bytes.length} status=$code '
        'try=${attempt + 1}',
      );
      if (code == 200) return true;
      // 400 (bad params) and 413 (too big) will not change on a retry;
      // 409 (sha mismatch, a corrupted body in flight) and errors might.
      if (code == 400 || code == 413) return false;
      if (attempt < delays.length) {
        await Future<void>.delayed(delays[attempt]);
      }
    }
    return false;
  }

  Future<void> _serve(JourneyJob job) async {
    if (job.blackout != null) {
      await _serveBlackout(job, job.blackout!);
      return;
    }
    status.value = 'job ${job.run}: preparing';
    _note('job run=${job.run} key=${job.key} hold=${job.holdS}s');
    // The whitelist profile's config is parsed BEFORE anything is built: a
    // job whose `url` is missing has no door to measure, and a run that
    // quietly skipped the loop would report an empty door_samples and read
    // like a pass.
    WhitelistDoorConfig? whitelistConfig;
    if (job.whitelist != null) {
      try {
        whitelistConfig = WhitelistDoorConfig.parse(job.whitelist!);
      } on FormatException catch (error) {
        _note('whitelist job rejected: ${error.message}');
        await _report('failed', <String, Object?>{
          'error': 'whitelist config: ${error.message}',
        });
        return;
      }
      _note('whitelist ${jsonEncode(whitelistConfig.toJson())}');
    }
    // The dnsvalve profile's config is parsed at arm time for the same
    // reason: a job whose zone or message size cannot produce a row is a
    // runner bug, and a call that ran anyway would report a lane failure
    // that never happened.
    DnsValveConfig? valveConfig;
    if (job.dnsValve != null) {
      try {
        valveConfig = DnsValveConfig.parse(job.dnsValve!);
      } on FormatException catch (error) {
        _note('dns valve job rejected: ${error.message}');
        await _report('failed', <String, Object?>{
          'error': 'dns_valve config: ${error.message}',
        });
        return;
      }
      _note('dns valve ${jsonEncode(valveConfig.toJson())}');
    }
    final relay = await LoopbackRelay.start(); // remote: no in-process server
    // Under the dnsvalve filter every UDP port but 53 and the valve's is
    // dropped too, so its jobs take the same relay-only path the whitelist
    // profile does.
    final relayOnly =
        whitelistConfig?.relayOnly ?? valveConfig?.relayOnly ?? false;
    final stack = E2eCallStack.build(
      endpoint: relay.endpoint,
      callId: job.key,
      role: CallRole.initiator,
      mode: _mode!,
      // Under the whitelist filter every UDP port but 53 is dropped, so the
      // phone must not try a UDP TURN allocation at all: relay-only over the
      // TCP TURN URL, taken from e2e_support's own list so the credentials
      // and host stay in one place.
      iceServersOverride: relayOnly ? e2eIceServersTcpOnly() : null,
      iceTransportPolicyOverride: relayOnly ? 'relay' : null,
    );
    final WhitelistDoor? door = whitelistConfig == null
        ? null
        : _buildWhitelistDoor(whitelistConfig, job.run);
    // The loop and the two controls run BESIDE the call, never in place of
    // it: they are unawaited, they never throw, and nothing in the call
    // path waits on them.
    if (door != null) {
      unawaited(door.run());
      unawaited(_reportWhitelistControls(door, job.run));
    }
    Map<String, Object?> whitelistEvidence = const <String, Object?>{};
    final lanes = _Lanes(this, stack, job.run);
    final startedAt = DateTime.now();
    // Held, not fire-and-forget: unlike the door loop, this branch produces
    // the row's evidence, and the hub drops anything posted after `ended`.
    Future<void>? dnsValveTask;
    try {
      // The lanes are requested now and resolve once the controller starts
      // the media engine (openDataChannel waits for start); the receivers
      // must exist before the first frame can arrive.
      final lanesReady = lanes.open();
      await _report('stack_up', <String, Object?>{
        'media': _mode!.name,
        'relay': relay.endpoint.toString(),
        'budget_s': journeyConnectBudgetS,
      });
      // Beside the call, never in place of it: the fabric is its own stack
      // and nothing in the call path waits on it until `ended` is due.
      if (valveConfig != null) {
        dnsValveTask = _serveDnsValve(job, valveConfig);
      }
      status.value = 'job ${job.run}: waiting for go';
      final goDeadline = DateTime.now().add(const Duration(minutes: 10));
      while (!await _goRaised(job.run)) {
        if (DateTime.now().isAfter(goDeadline)) {
          throw TimeoutException('GO was never raised for ${job.run}');
        }
        await Future<void>.delayed(const Duration(seconds: 1));
      }
      _note('go: starting the call');
      status.value = 'job ${job.run}: calling';
      unawaited(stack.controller.start());
      await lanesReady;
      final connected = await stack.waitForConnected(
        timeout: Duration(seconds: journeyConnectBudgetS),
      );
      final connectMs = DateTime.now().difference(startedAt).inMilliseconds;
      _note('connected phase=${connected.phase.name} connect_ms=$connectMs');
      await _report('connected', <String, Object?>{
        'phase': connected.phase.name,
        'connect_ms': connectMs,
      });
      status.value = 'job ${job.run}: connected';

      // The whitelist row's media proof, measured once the call is up and
      // before the hold loop starts reading the same counters: WHICH pair
      // carries the audio, and whether received packets really advance.
      if (door != null) {
        whitelistEvidence = await _whitelistIceEvidence(stack);
        _note('whitelist ice ${jsonEncode(whitelistEvidence)}');
      }

      final holdUntil = DateTime.now().add(Duration(seconds: job.holdS));
      while (DateTime.now().isBefore(holdUntil)) {
        await Future<void>.delayed(const Duration(seconds: 2));
        // Terminal FIRST: the sample loop of the old peer test read counters
        // off a port the remote hangup had already closed and failed the
        // whole run on a StateError (latency/loss10/loss60/extreme logs).
        if (stack.controller.state.isTerminal) break;
        final counters = await _counters(stack);
        final elapsed = DateTime.now().difference(startedAt).inSeconds;
        await _report('sample', <String, Object?>{
          't_s': elapsed,
          'phase': stack.controller.state.phase.name,
          'rx': counters?.packetsReceived,
          'lost': counters?.packetsLost,
          'tx': counters?.packetsSent,
        });
      }
      if (!stack.controller.state.isTerminal) {
        _note('hold expired: hanging up');
        await stack.controller.hangUp();
      }
      final done = await stack.controller.done.timeout(
        const Duration(seconds: 30),
      );
      _note('ended phase=${done.phase.name} reason=${done.endReason?.name}');
      // The hub writes job.done on `ended`, and the runner stops waiting
      // then — a blob posted after it is lost, so every post lands first.
      // The dnsvalve branch's events are evidence for the same reason, so
      // it is joined here rather than left running.
      await _joinDnsValve(dnsValveTask, job, valveConfig);
      await lanes.drainBlobs();
      await _report('ended', <String, Object?>{
        'phase': done.phase.name,
        'reason': done.endReason?.name,
        'phases': stack.recentPhases(),
        ...lanes.summary(),
        if (door != null) 'door_samples': door.samplesJson(),
        ...whitelistEvidence,
      });
    } on Object catch (error) {
      _note(
        'failed error=$error last_phase=${stack.controller.state.phase.name}',
      );
      await _joinDnsValve(dnsValveTask, job, valveConfig);
      await lanes.drainBlobs(); // same reason as before `ended`
      await _report('failed', <String, Object?>{
        'error': '$error',
        'last_phase': stack.controller.state.phase.name,
        'phases': stack.recentPhases(),
        ...lanes.summary(),
        if (door != null) 'door_samples': door.samplesJson(),
        ...whitelistEvidence,
      });
    } finally {
      // The loop outlives neither the job nor the call: stopped here so the
      // next job starts with its own door.
      door?.stop();
      await lanes.close();
      await stack.dispose();
      await relay.close();
      status.value = 'job ${job.run}: finished';
    }
  }

  /// The door with its real, dart:io seams: one HttpClient that accepts the
  /// rig's dev certificate for the configured host only, a plain TCP
  /// connect, and one QUIC-shaped datagram.
  WhitelistDoor _buildWhitelistDoor(WhitelistDoorConfig config, String run) {
    return WhitelistDoor(
      config: config,
      http: _DoorHttpClient(Uri.parse(config.url).host),
      tcp: const _DoorTcpConnector(),
      udp: const _DoorUdpProber(),
      clock: const SystemDoorClock(),
      log: _note,
      onOpen: (open) =>
          unawaited(_report('door_open', open.toJson(), run: run)),
    );
  }

  /// The two negative controls, once each, reported as they land. Never
  /// throws: the door's own probes already turn every failure into an
  /// outcome, and the call must not depend on this.
  Future<void> _reportWhitelistControls(WhitelistDoor door, String run) async {
    final reset = await door.probeResetElsewhere();
    await _report('door_closed_elsewhere', reset.toJson(), run: run);
    final quic = await door.probeQuicDead();
    await _report('quic_dead', quic.toJson(), run: run);
  }

  /// The whitelist row's media proof: which candidate pair carries the
  /// audio, and whether the received-packet counter really advances.
  ///
  /// `ice_pair_protocol` is the leg THIS phone put on the wire — a relay
  /// candidate's `relayProtocol` when it has one, its own protocol
  /// otherwise (see [SelectedIcePair.wireProtocol]). Classic TURN still
  /// relays to the far peer over UDP on the server's own leg; what this
  /// proves is that the phone emitted no UDP and still carried live audio.
  Future<Map<String, Object?>> _whitelistIceEvidence(E2eCallStack stack) async {
    final port = stack.port;
    if (port == null) {
      return <String, Object?>{
        'ice_pair_type': null,
        'ice_pair_protocol': null,
        'rx_increasing': null,
      };
    }
    SelectedIcePair? pair;
    try {
      pair = await port.readSelectedIcePair().timeout(
        const Duration(seconds: 5),
      );
    } on Object catch (error) {
      _note('whitelist ice pair unreadable: $error');
    }
    bool? rxIncreasing;
    try {
      await samplePacketsReceivedStrictlyIncreasing(
        port,
        label: 'whitelist phone rx',
      );
      rxIncreasing = true;
    } on TimeoutException catch (error) {
      _note('whitelist rx did not increase: ${error.message}');
      rxIncreasing = false;
    } on Object catch (error) {
      _note('whitelist rx sampling failed: $error');
    }
    return <String, Object?>{
      'ice_pair_type': pair?.localCandidateType,
      'ice_pair_protocol': pair?.wireProtocol,
      'rx_increasing': rxIncreasing,
    };
  }

  /// The blackout job: no call. A signed bundle of [bytes] is created at T0,
  /// put in the DURABLE store-and-forward queue (survives a process restart),
  /// and the phone probes the hub every [probeS] seconds with one cheap GET.
  /// The first probe that answers opens the queue's flush: the bundle is
  /// POSTed to /bundle, the Mac verifies the Ed25519 signature and records
  /// the arrival. Delivery time is whatever the link allowed — hours, not
  /// seconds — and the row reports it in hours.
  /// The dnsvalve profile's branch: a fabric of the three fallback lanes
  /// built BESIDE the call, refreshed until the DNS valve ranks first, then
  /// used to carry one deterministic message over it.
  ///
  /// Its own fabric on purpose: the peer's call path builds an
  /// [E2eCallStack], which constructs no [ConnectionFabric] at all, so a
  /// build's DNS_VALVE_* defines carry no lane until something registers
  /// one. This is that something.
  ///
  /// Never throws and never stays silent. Every outcome — registered,
  /// wan_probe, selected/not_selected, lane_chat, gave_up, error — is an
  /// event on the hub, because the Mac reads the row's FAIL reason off
  /// these events and an absent event reads as "the branch never ran".
  Future<void> _serveDnsValve(JourneyJob job, DnsValveConfig config) async {
    try {
      await _runDnsValve(job, config);
    } on Object catch (error) {
      _note('dns valve error=$error');
      await _report('lane', <String, Object?>{
        'stage': 'error',
        'error': '$error',
      }, run: job.run);
    }
  }

  Future<void> _runDnsValve(JourneyJob job, DnsValveConfig config) async {
    // Only the two WAN lanes are taken from the shared helper: its own
    // valve is built from this build's compile-time defines, and the rig
    // must be able to re-aim the zone and the resolvers per job, without a
    // reinstall.
    final endpoints = defaultBorderRelayEndpoints(
      callId: job.key,
      role: CallRole.initiator,
    );
    // failThreshold 20, not forValve's default 5: probe() is a real send,
    // so at one refresh every 12 s the default would let five unanswered
    // probes declare the valve DOWN — terminally — inside the 60 s window,
    // before it had a chance to rank first.
    final valve = TxtQueryLane.forValve(
      TxtQueryValve(domain: config.zone, resolvers: config.resolvers),
      failThreshold: 20,
    );
    final relayUri = endpoints.relayUri;
    final longPollUri = endpoints.longPollUri;
    final wss = relayUri == null
        ? null
        : WebSocketRelayLane(relayUri: relayUri);
    final longPoll = longPollUri == null
        ? null
        : HttpLongPollLane(sendUri: longPollUri);
    final fabric = ConnectionFabric(
      fallbackQueue: DtnBundleQueue(),
      nowMs: () => DateTime.now().millisecondsSinceEpoch,
    );
    try {
      final ids = ResilientFallbackLanes.registerAll(
        fabric,
        webSocketRelay: wss,
        httpLongPoll: longPoll,
        txtQuery: valve,
      );
      _note('dns valve lanes=${ids.join(',')} zone=${config.zone}');
      await _report('lane', <String, Object?>{
        'stage': 'registered',
        'ids': ids,
        'zone': config.zone,
        'resolvers': [
          for (final resolver in config.resolvers)
            '${resolver.host}:${resolver.port}',
        ],
        'best_lane_id': fabric.snapshot.bestLaneId,
        'mode': fabric.snapshot.mode.name,
      }, run: job.run);

      await _reportWanProbe(job, relayUri?.host ?? longPollUri?.host);

      final Uint8List letterPayload;
      final String letterKind;
      final bool letterSubmitted;
      if (config.chatSource == 'phone') {
        (letterPayload, letterKind, letterSubmitted) = await _awaitPhoneLetter(
          job,
          config,
        );
      } else {
        letterPayload =
            config.chatText ?? dnsValvePayload(job.run, config.chatBytes);
        letterKind = 'mac';
        letterSubmitted = false;
      }
      final deadline = DateTime.now().add(config.totalBudget);
      final selected = await _awaitValveSelection(job, fabric, valve, config);
      await _carryOverValve(
        job,
        fabric,
        valve,
        config,
        selected,
        deadline,
        letterPayload,
        letterKind,
        letterSubmitted,
      );
    } finally {
      // dispose() closes the snapshot stream and nothing else — the fabric
      // never touches channels it did not create, so the WSS socket and the
      // valve's UDP socket are closed here or they outlive the job.
      try {
        await fabric.dispose();
        await wss?.dispose();
        await longPoll?.dispose();
        await valve.dispose();
      } on Object catch (error) {
        _note('dns valve dispose error=$error');
      }
    }
  }

  /// One HTTPS GET to the border relay host, before the loop starts.
  ///
  /// The rig's filter only shapes bridge100, so a phone that still has
  /// Wi-Fi or cellular can reach the WAN lanes the profile means to remove.
  /// Without this control, a run where the valve never ranked first because
  /// the relay was alive is indistinguishable from one where the valve was
  /// simply down.
  Future<void> _reportWanProbe(JourneyJob job, String? host) async {
    var reachable = false;
    int? status;
    String? error;
    if (host == null || host.isEmpty) {
      error = 'no border relay host configured';
    } else {
      try {
        final request = await _http
            .getUrl(Uri.https(host, '/'))
            .timeout(const Duration(seconds: 5));
        final response = await request.close().timeout(
          const Duration(seconds: 5),
        );
        status = response.statusCode;
        await response.drain<void>();
        reachable = true;
      } on Object catch (failure) {
        error = '$failure';
      }
    }
    _note('dns valve wan_probe host=$host reachable=$reachable');
    await _report('lane', <String, Object?>{
      'stage': 'wan_probe',
      'reachable': reachable,
      'host': host,
      'status': ?status,
      'error': ?error,
    }, run: job.run);
  }

  /// Refreshes the fabric until the valve ranks first or the select budget
  /// runs out, then reports the ranking that decided it.
  ///
  /// Every 12 s, never faster: [TxtQueryLane.probe] is a real send charged
  /// against the lane's failure window, so a tighter cadence spends the
  /// lane's budget on the loop's own probes. The per-lane scores ride the
  /// event so a valve that was DOWN shows up as that, rather than reading
  /// like a lane that merely never won.
  Future<bool> _awaitValveSelection(
    JourneyJob job,
    ConnectionFabric fabric,
    TxtQueryLane valve,
    DnsValveConfig config,
  ) async {
    final deadline = DateTime.now().add(config.selectBudget);
    var refreshes = 0;
    var selected = false;
    while (true) {
      await fabric.refresh();
      refreshes++;
      selected = fabric.snapshot.bestLaneId == ResilientLaneIds.txtQuery;
      status.value =
          'job ${job.run}: probing the door · refresh $refreshes · '
          'best=${fabric.snapshot.bestLaneId ?? 'none'}';
      if (selected || !DateTime.now().isBefore(deadline)) break;
      await Future<void>.delayed(const Duration(seconds: 12));
    }
    final snapshot = fabric.snapshot;
    _note(
      'dns valve ${selected ? 'selected' : 'not_selected'} '
      'best=${snapshot.bestLaneId} refreshes=$refreshes',
    );
    await _report('lane', <String, Object?>{
      'stage': selected ? 'selected' : 'not_selected',
      'best_lane_id': snapshot.bestLaneId,
      'mode': snapshot.mode.name,
      'lanes': [
        for (final lane in snapshot.lanes)
          <String, Object?>{
            'id': lane.id,
            'eligible': lane.eligible,
            'score': lane.score,
          },
      ],
      'valve_score': valve.health.score(),
      'valve_down': valve.isDown,
      'valve_attempts': valve.attempts,
      'valve_replies': valve.replies,
      'refreshes': refreshes,
      'select_budget_s': config.selectBudget.inSeconds,
    }, run: job.run);
    return selected;
  }

  /// Waits for the phone's Send window (if the job opened one), then
  /// returns the payload and how it was chosen. `phoneWait == Duration.zero`
  /// returns immediately — an unattended run behaves exactly as before this
  /// window existed. Priority once the window closes (submit or timeout):
  /// a voice recording taken during this window, else the typed draft, else
  /// the honest default letter.
  Future<(Uint8List, String, bool)> _awaitPhoneLetter(
    JourneyJob job,
    DnsValveConfig config,
  ) async {
    if (config.phoneWait == Duration.zero) {
      final text = draft.value.trim();
      final kind = text.isEmpty ? 'default' : 'typed';
      final bytes = text.isEmpty ? phoneDefaultLetter(job.run) : text;
      return (Uint8List.fromList(utf8.encode(bytes)), kind, false);
    }
    letterWanted.value = true;
    final gate = _letterGate = Completer<void>();
    final started = DateTime.now();
    final ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      final left = config.phoneWait - DateTime.now().difference(started);
      final leftS = left.isNegative ? 0 : left.inSeconds;
      status.value =
          'job ${job.run}: your turn — type the letter, or tap Record and '
          'speak, then tap Send (${leftS}s left)';
    });
    try {
      await gate.future.timeout(config.phoneWait, onTimeout: () {});
    } finally {
      ticker.cancel();
      _letterGate = null;
      letterWanted.value = false;
    }
    // A Send tap mid-recording finalizes what was captured so far, and a
    // tap that is still encoding gets to finish — the letter is read after
    // the recording has settled, never out from under it.
    await finalizeRecording();
    final submitted = gate.isCompleted;
    final waitedMs = DateTime.now().difference(started).inMilliseconds;
    final voice = voiceLetter.value;
    voiceLetter.value = null;
    // The button belongs to the window that is closing: a "Recorded 0:30"
    // left over from the letter just carried would read, in the next
    // window, as a take that window already holds.
    recordState.value = VoiceRecordState.idle;
    recordElapsed.value = Duration.zero;
    final (kind, bytes) = voice != null
        ? ('voice', voice.wire)
        : draft.value.trim().isEmpty
        ? (
            'default',
            Uint8List.fromList(utf8.encode(phoneDefaultLetter(job.run))),
          )
        : ('typed', Uint8List.fromList(utf8.encode(draft.value.trim())));
    _note(
      'phone letter window closed: kind=$kind submitted=$submitted '
      'waited_ms=$waitedMs',
    );
    await _report('lane', <String, Object?>{
      'stage': 'letter',
      'kind': kind,
      'submitted': submitted,
      'waited_ms': waitedMs,
    }, run: job.run);
    return (bytes, kind, submitted);
  }

  /// Carries one deterministic payload and reports what attributes it.
  ///
  /// `best_lane_at_send` is read BEFORE the delivery: deliver() republishes
  /// the snapshot on its way out, and two of the fabric's three strategies
  /// put the same payload on several lanes at once, so the id read
  /// afterwards is a post-hoc ranking and not the lane that carried the
  /// bytes. What does attribute the message is `session_id` — the valve's
  /// own per-message id — matched against the responder's log line, which
  /// only TXT-lane datagrams can produce.
  Future<void> _carryOverValve(
    JourneyJob job,
    ConnectionFabric fabric,
    TxtQueryLane valve,
    DnsValveConfig config,
    bool selected,
    DateTime deadline,
    Uint8List payload,
    String letterKind,
    bool letterSubmitted,
  ) async {
    final remaining = deadline.difference(DateTime.now());
    final budget = remaining < const Duration(seconds: 1)
        ? const Duration(seconds: 1)
        : remaining;
    // Refused HERE, not by the lane's own throw: deliver() fans out, and an
    // over-cap letter refused by the valve could still ride another lane and
    // produce a lane_chat that reads as a carriage. Same event the branch's
    // catch-all writes, so the row builder needs no new stage.
    if (payload.length > TxtQueryLane.maxPayloadBytes) {
      _note('letter refused: ${payload.length} B over the lane limit');
      status.value =
          'job ${job.run}: letter too long — ${payload.length} B, '
          'the door takes ${TxtQueryLane.maxPayloadBytes}';
      await _report('lane', <String, Object?>{
        'stage': 'error',
        'phase': 'carry',
        'error': 'letter too long',
        'bytes': payload.length,
        'limit': TxtQueryLane.maxPayloadBytes,
        'source': config.chatSource,
      }, run: job.run);
      return;
    }
    final sha = contentSha256Hex(payload);
    final bestAtSend = fabric.snapshot.bestLaneId;
    // The screen's view of the carriage, rewritten once a second from the
    // lane's counters. Both counters are lane-lifetime and every refresh()
    // in the selection loop probed, so they are baselined here; a late
    // duplicate answer can count a chunk twice, so landed is clamped to the
    // total. The callback never awaits and never throws past itself.
    final attemptsAtStart = valve.attempts;
    final repliesAtStart = valve.replies;
    final total = txtChunkCount(payload.length);
    var lastReplies = repliesAtStart;
    DateTime? lastReplyAt;
    String beat() {
      final replies = valve.replies;
      if (replies > lastReplies) {
        lastReplies = replies;
        lastReplyAt = DateTime.now();
      }
      final landedRaw = replies - repliesAtStart;
      final at = lastReplyAt;
      return doorLine(
        down: valve.isDown,
        attempts: valve.attempts - attemptsAtStart,
        landed: landedRaw > total ? total : landedRaw,
        total: total,
        sinceReply: at == null ? null : DateTime.now().difference(at),
      );
    }

    letter.value = describeLetter(payload, sha);
    _note('letter handed to the valve: ${payload.length} B, $total chunks');
    status.value = 'job ${job.run}: ${beat()}';
    final heartbeat = Timer.periodic(const Duration(seconds: 1), (_) {
      try {
        status.value = 'job ${job.run}: ${beat()}';
      } on Object catch (error) {
        _note('heartbeat error=$error');
      }
    });
    try {
      final outcome = await fabric
          .deliver(
            payload,
            bundleId: '${job.run}-dns-valve',
            priority: LinkMessagePriority.callSignal,
          )
          .timeout(budget);
      _note(
        'dns valve carried outcome=${outcome.name} '
        'session=${valve.lastSessionId} sha256=$sha',
      );
      status.value = 'job ${job.run}: letter ${outcome.name} · ${beat()}';
      await _report('lane_chat', <String, Object?>{
        'outcome': outcome.name,
        'best_lane_at_send': bestAtSend,
        'selected': selected,
        'session_id': valve.lastSessionId,
        'sha256': sha,
        'bytes': payload.length,
        'source': config.chatSource,
        'letter_kind': letterKind,
        'letter_submitted': letterSubmitted,
        'valve_down': valve.isDown,
        'valve_attempts': valve.attempts,
        'valve_replies': valve.replies,
        // The plan that decided the attempt set, so the next parked
        // payload is diagnosable from this event alone: on 2026-09-13 the
        // valve counters had to stand in for it.
        'plan': <String, Object?>{
          'strategy': fabric.lastPlan?.strategy.name,
          'lane_ids': fabric.lastPlan?.laneIds,
          'grounds': fabric.lastPlan?.explanation?.grounds,
        },
      }, run: job.run);
    } on TimeoutException {
      _note('dns valve gave_up after ${budget.inSeconds}s');
      // timeout() abandons the future, it does not cancel the send: the
      // lane keeps working until dispose, and a frozen "alive" line would
      // claim otherwise.
      status.value =
          'job ${job.run}: gave up after ${budget.inSeconds}s · ${beat()} · '
          'lane draining until dispose';
      await _report('lane', <String, Object?>{
        'stage': 'gave_up',
        'phase': 'carry',
        'carry_budget_s': budget.inSeconds,
        'best_lane_at_send': bestAtSend,
        'selected': selected,
        'session_id': valve.lastSessionId,
        'sha256': sha,
        'bytes': payload.length,
        'valve_score': valve.health.score(),
        'valve_down': valve.isDown,
        'valve_attempts': valve.attempts,
        'valve_replies': valve.replies,
      }, run: job.run);
    } finally {
      heartbeat.cancel();
    }
  }

  /// Joins the dnsvalve branch before `ended` is reported.
  ///
  /// Same reason the blobs are drained there: the hub writes job.done on
  /// `ended` and drops whatever arrives after it, so a branch left running
  /// past the hang-up produces no events at all and the Mac reports a
  /// branch that never ran. The guard is the branch's own budget plus
  /// slack — a last resort, since both phases already bound themselves —
  /// and a guard that fires still leaves an event behind.
  Future<void> _joinDnsValve(
    Future<void>? task,
    JourneyJob job,
    DnsValveConfig? config,
  ) async {
    if (task == null || config == null) return;
    final guard =
        config.totalBudget + config.phoneWait + const Duration(seconds: 20);
    var expired = false;
    try {
      await task.timeout(
        guard,
        onTimeout: () {
          expired = true;
        },
      );
    } on Object catch (error) {
      _note('dns valve join error=$error');
    }
    if (expired) {
      await _report('lane', <String, Object?>{
        'stage': 'gave_up',
        'phase': 'join',
        'guard_s': guard.inSeconds,
      }, run: job.run);
    }
  }

  Future<void> _serveBlackout(JourneyJob job, Map<String, Object?> cfg) async {
    _lastRun = job.run;
    final plan = BlackoutPlan.parse(cfg);
    if (plan != null) {
      await _serveBlackoutV2(job, plan);
      return;
    }
    final bytes = cfg['bytes'] is int ? cfg['bytes']! as int : 1024;
    final probeS = cfg['probe_s'] is int ? cfg['probe_s']! as int : 20;
    final lifetimeS = cfg['lifetime_s'] is int
        ? cfg['lifetime_s']! as int
        : 6 * 3600;
    _note(
      'blackout job run=${job.run} bytes=$bytes probe=${probeS}s '
      'lifetime=${lifetimeS}s',
    );
    status.value = 'job ${job.run}: blackout — holding $bytes B';

    final createdMs = DateTime.now().toUtc().millisecondsSinceEpoch;
    final header = utf8.encode(
      jsonEncode({'run': job.run, 'created_ms': createdMs, 'bytes': bytes}),
    );
    final random = Random.secure();
    final payload = Uint8List(bytes);
    payload.setRange(0, min(header.length, bytes), header);
    for (var i = header.length; i < bytes; i++) {
      payload[i] = random.nextInt(256);
    }
    final sha = contentSha256Hex(payload);
    final id = sha.substring(0, 16);
    final signature = await Ed25519().sign(payload, keyPair: _keyPair!);
    final envelope = utf8.encode(
      jsonEncode({
        'run': job.run,
        'id': id,
        'created_ms': createdMs,
        'payload': base64Encode(payload),
        'sig': base64Encode(signature.bytes),
        'pubkey': _pubkeyB64,
      }),
    );
    final store = DurableBundleStore.open(
      File('${Directory.systemTemp.path}/journey_blackout_bundles.jsonl'),
    );
    final queue = DtnBundleQueue(store: store);
    final admission = queue.offer(
      DtnBundle(
        id: id,
        payload: envelope,
        priority: LinkMessagePriority.bulk,
        createdAtMs: createdMs,
        lifetimeMs: lifetimeS * 1000,
      ),
      nowMs: createdMs,
    );
    _note('bundle $id queued ($admission), sha256=$sha');
    // The last event that can leave before the runner cuts the link.
    await _report('blackout_armed', <String, Object?>{
      'id': id,
      'sha256': sha,
      'created_ms': createdMs,
      'bytes': bytes,
      'probe_s': probeS,
      'lifetime_s': lifetimeS,
      'store': 'durable',
    }, run: job.run);

    var probes = 0;
    var reachable = 0;
    int? deliveredMs;
    final deadlineMs = createdMs + lifetimeS * 1000;
    while (DateTime.now().toUtc().millisecondsSinceEpoch < deadlineMs) {
      await Future<void>.delayed(Duration(seconds: probeS));
      probes++;
      final heldS =
          (DateTime.now().toUtc().millisecondsSinceEpoch - createdMs) ~/ 1000;
      status.value =
          'job ${job.run}: holding $bytes B for ${heldS}s, probe $probes';
      if (!await _hubReachable()) continue;
      reachable++;
      final nowMs = DateTime.now().toUtc().millisecondsSinceEpoch;
      final sent = await queue.flush(_postBundle, nowMs: nowMs);
      if (sent > 0) {
        deliveredMs = DateTime.now().toUtc().millisecondsSinceEpoch;
        break;
      }
    }
    if (deliveredMs != null) {
      final latencyS = (deliveredMs - createdMs) / 1000.0;
      _note(
        'bundle $id delivered after ${latencyS.toStringAsFixed(0)}s, '
        'probes=$probes reachable=$reachable',
      );
      status.value = 'job ${job.run}: delivered after ${latencyS ~/ 60} min';
      await _report('ended', <String, Object?>{
        'phase': 'ended',
        'reason': 'bundleDelivered',
        'delivered_ms': deliveredMs,
        'latency_s': latencyS,
        'probes': probes,
        'reachable_probes': reachable,
      }, run: job.run);
    } else {
      _note('bundle $id NOT delivered within ${lifetimeS}s, probes=$probes');
      status.value = 'job ${job.run}: bundle expired undelivered';
      await _report('failed', <String, Object?>{
        'error': 'bundle not delivered within ${lifetimeS}s',
        'last_phase': 'blackout',
        'probes': probes,
        'reachable_probes': reachable,
      }, run: job.run);
    }
  }

  /// The v2 blackout job: the window is a gate, not a probe. A plan of
  /// bundles with real sizes and priorities is signed at T0 and kept in the
  /// durable queue; a 2 s probe (one 60-byte GET) finds the window, and the
  /// first probe that answers flushes the WHOLE queue in priority-then-age
  /// order until the link drops or nothing is left. Bundles larger than the
  /// chunk size travel as chunks with per-chunk acks, so a window that
  /// closes mid-transfer keeps its progress on the hub and the next window
  /// resumes from the first missing chunk. The runner shapes the window at
  /// 16 kbit/s, so bytes delivered per window is a utilization figure.
  ///
  /// A v3 plan keeps the same probe loop and queue but flushes over the
  /// framed TCP stream lane ([_streamFlush]) instead of the chunked HTTP
  /// forwarder: one connection per probe answer, resumed from the hub's
  /// byte offset, removed from the queue on the hub's `done`.
  Future<void> _serveBlackoutV2(JourneyJob job, BlackoutPlan plan) async {
    final total = plan.items.length;
    final streamPort = BlackoutStreamParams.portOf(plan.stream);
    // Arm-time gate: a plan that can never deliver (no items, or a v3 plan
    // whose stream map carries no usable port) fails now, not after
    // lifetime_s of probes that each return before writing a byte.
    final rejection = blackoutPlanRejection(plan);
    if (rejection != null) {
      _note('blackout v${plan.v} job run=${job.run}: $rejection');
      await _report('failed', <String, Object?>{
        'error': rejection,
        'last_phase': 'blackout',
        'delivered': 0,
        'remaining': 0,
        if (plan.v == 3) 'stream': true,
      }, run: job.run);
      return;
    }
    _note(
      'blackout v${plan.v} job run=${job.run} bundles=$total '
      'bytes=${plan.bytesTotal} probe=${plan.probeS}s '
      'chunk=${plan.chunkBytes} lifetime=${plan.lifetimeS}s'
      '${plan.v == 3 ? ' stream_port=$streamPort' : ''}',
    );
    status.value =
        'job ${job.run}: blackout v${plan.v} — holding $total bundles';
    // Without the wakelock iOS suspends the app once the screen locks and
    // the probe stops; the state is logged so a gap in the probe count has
    // its explanation on the phone's own event list.
    try {
      _note('wakelock enabled=${await WakelockPlus.enabled}');
    } on Object catch (error) {
      _note('wakelock state unknown: $error');
    }

    final createdMs = DateTime.now().toUtc().millisecondsSinceEpoch;
    final random = Random.secure();
    // One store file per run: a leftover from an earlier run must not ride
    // along, while a restart of the same run resumes its own queue.
    final safeRun = job.run.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final store = DurableBundleStore.open(
      File('${Directory.systemTemp.path}/journey_blackout_v2_$safeRun.jsonl'),
    );
    final queue = DtnBundleQueue(store: store);
    final ids = <String>[];
    final payloadBytes = <String, int>{};
    // Envelope size per id: the v3 flush removes a bundle from the queue on
    // the hub's done, so its wire size is looked up here, not on the bundle.
    final envelopeBytes = <String, int>{};
    for (final item in plan.items) {
      final payload = blackoutPayload(
        run: job.run,
        item: item,
        createdMs: createdMs,
        random: random,
      );
      final id = contentSha256Hex(payload).substring(0, 16);
      final signature = await Ed25519().sign(payload, keyPair: _keyPair!);
      final envelope = buildBlackoutEnvelope(
        run: job.run,
        id: id,
        createdMs: createdMs,
        payload: payload,
        signature: signature.bytes,
        pubkeyB64: _pubkeyB64!,
      );
      final admission = queue.offer(
        DtnBundle(
          id: id,
          payload: envelope,
          priority: item.priority,
          createdAtMs: createdMs,
          lifetimeMs: plan.lifetimeS * 1000,
        ),
        nowMs: createdMs,
      );
      if (admission != BundleAdmission.stored) {
        _note('bundle $id ($item) not queued: ${admission.name}');
      }
      ids.add(id);
      payloadBytes[id] = item.bytes;
      envelopeBytes[id] = envelope.length;
    }
    _note(
      '${ids.length} bundles queued, '
      '${queue.pendingInDeliveryOrder(createdMs).length} pending',
    );
    // The last event that can leave before the runner cuts the link.
    await _report('blackout_armed', <String, Object?>{
      'v': plan.v,
      if (plan.stream != null) 'stream': plan.stream,
      'bundles': total,
      'bytes_total': plan.bytesTotal,
      'ids': ids,
      'created_ms': createdMs,
      'probe_s': plan.probeS,
      'chunk_bytes': plan.chunkBytes,
      'lifetime_s': plan.lifetimeS,
      'store': 'durable',
    }, run: job.run);

    final forwarder = BlackoutForwarder(
      _HubBlackoutTransport(this),
      chunkBytes: plan.chunkBytes,
      log: _note,
    );
    var probes = 0;
    var reachable = 0;
    var delivered = 0;
    var deliveredBytes = 0;
    var deliveredWireBytes = 0;
    int? lastDeliveredMs;
    // Payload bytes the stream lane wrote and the hub acked, summed
    // over every v3 session of this job (bytes_written - bytes_acked
    // is what was in flight when the sessions ended).
    var streamBytesWritten = 0;
    var streamBytesAcked = 0;
    // One record delivered, on either lane: [how] names the evidence
    // (chunk count for v2, the hub's verdict for v3).
    void recordDelivered(String id, String how) {
      delivered++;
      deliveredBytes += payloadBytes[id] ?? 0;
      deliveredWireBytes += envelopeBytes[id] ?? 0;
      lastDeliveredMs = DateTime.now().toUtc().millisecondsSinceEpoch;
      _note('bundle $id delivered ($delivered/$total, $how)');
      status.value = 'job ${job.run}: delivered $delivered/$total';
    }

    Future<bool> forward(DtnBundle bundle) async {
      final ok = await forwarder.forward(
        id: bundle.id,
        envelope: bundle.payload,
        sha256: contentSha256Hex(bundle.payload),
      );
      if (ok) {
        recordDelivered(bundle.id, '${forwarder.lastChunksPosted} chunks');
      }
      return ok;
    }

    final deadlineMs = createdMs + plan.lifetimeS * 1000;
    var nowMs = createdMs;
    while (nowMs < deadlineMs) {
      await Future<void>.delayed(Duration(seconds: plan.probeS));
      probes++;
      nowMs = DateTime.now().toUtc().millisecondsSinceEpoch;
      final heldS = (nowMs - createdMs) ~/ 1000;
      status.value =
          'job ${job.run}: $delivered/$total delivered, held ${heldS}s, '
          'probe $probes';
      // The probe and a flush never overlap: the flush is awaited before
      // the next probe, so the 60-byte GET never competes with a chunk for
      // the 16 kbit/s gate.
      if (!await _hubReachable()) continue;
      reachable++;
      if (plan.v == 3) {
        final lane = await _streamFlush(
          run: job.run,
          plan: plan,
          queue: queue,
          nowMs: nowMs,
          onDone: (id, sigOk, pubkeyMatch) => recordDelivered(
            id,
            'stream sig_ok=$sigOk pubkey_match=$pubkeyMatch',
          ),
        );
        if (lane != null) {
          streamBytesWritten += lane.bytesWritten;
          streamBytesAcked += lane.bytesAcked;
        }
      } else {
        await queue.flush(forward, nowMs: nowMs);
      }
      nowMs = DateTime.now().toUtc().millisecondsSinceEpoch;
      if (queue.pendingInDeliveryOrder(nowMs).isEmpty) break;
    }
    final remaining = total - delivered;
    if (remaining == 0 && lastDeliveredMs != null) {
      final latencyS = (lastDeliveredMs! - createdMs) / 1000.0;
      _note(
        'all $total bundles delivered after ${latencyS.toStringAsFixed(0)}s, '
        'probes=$probes reachable=$reachable',
      );
      status.value = 'job ${job.run}: delivered after ${latencyS ~/ 60} min';
      await _report('ended', <String, Object?>{
        'phase': 'ended',
        'reason': 'queueDelivered',
        'delivered': delivered,
        'bytes': deliveredBytes,
        'wire_bytes': deliveredWireBytes,
        'delivered_ms': lastDeliveredMs,
        'latency_s': latencyS,
        'probes': probes,
        'reachable_probes': reachable,
        if (plan.v == 3) ...<String, Object?>{
          'stream': true,
          'bytes_written': streamBytesWritten,
          'bytes_acked': streamBytesAcked,
        },
      }, run: job.run);
    } else {
      _note(
        '$remaining of $total bundles NOT delivered within '
        '${plan.lifetimeS}s, probes=$probes',
      );
      status.value = 'job ${job.run}: $remaining bundles expired undelivered';
      await _report('failed', <String, Object?>{
        'error': '$remaining bundles not delivered within ${plan.lifetimeS}s',
        'last_phase': 'blackout',
        'delivered': delivered,
        'remaining': remaining,
        'bytes': deliveredBytes,
        'wire_bytes': deliveredWireBytes,
        'probes': probes,
        'reachable_probes': reachable,
        if (plan.v == 3) ...<String, Object?>{
          'stream': true,
          'bytes_written': streamBytesWritten,
          'bytes_acked': streamBytesAcked,
        },
      }, run: job.run);
    }
  }

  /// The v3 flush: one framed TCP session per probe answer. Connects to
  /// the hub's stream port (the host of [journeyHubUrl], the port of the
  /// plan's stream map), offers the queue's pending bundles in delivery
  /// order to [BlackoutStreamLane.run] and removes each one from the
  /// queue on the hub's done, then reports it through [onDone]. Returns
  /// the lane for its counters, or null when no connection was made (the
  /// next probe retries, as the v2 flush does after its first failure).
  Future<BlackoutStreamLane?> _streamFlush({
    required String run,
    required BlackoutPlan plan,
    required DtnBundleQueue queue,
    required int nowMs,
    required void Function(String id, bool sigOk, bool pubkeyMatch) onDone,
  }) async {
    final port = BlackoutStreamParams.portOf(plan.stream);
    if (port == null) {
      _note('stream: plan carries no stream port');
      return null;
    }
    final host = Uri.parse(journeyHubUrl).host;
    final Socket socket;
    try {
      socket = await Socket.connect(
        host,
        port,
        timeout: const Duration(seconds: 10),
      );
    } on Object catch (error) {
      _note('stream: connect $host:$port failed: $error');
      return null;
    }
    // The hello and the record headers are small writes; with Nagle they
    // would wait for the hub's ACK of the previous small segment, and that
    // ACK rides behind up to inflight_bytes of queued data on the shaped
    // pipe (16 s at 16 kbit/s).
    socket.setOption(SocketOption.tcpNoDelay, true);
    final pending = queue.pendingInDeliveryOrder(nowMs);
    _note('stream: connected $host:$port, ${pending.length} pending');
    final lane = BlackoutStreamLane(port: port, log: _note);
    final outcome = await lane.run(
      run: run,
      pubkeyB64: _pubkeyB64!,
      pending: pending,
      link: _SocketLink(socket, log: _note),
      onDone: (id, sigOk, pubkeyMatch) {
        queue.acknowledge(id);
        onDone(id, sigOk, pubkeyMatch);
      },
    );
    _note(
      'stream: $outcome offered=${lane.recordsOffered} '
      'skipped=${lane.recordsSkipped} done=${lane.doneCount} '
      'written=${lane.bytesWritten} acked=${lane.bytesAcked}',
    );
    return lane;
  }

  /// One whole envelope to /bundle on the bulk client; true on 200. Used by
  /// the v2 forwarder for envelopes that fit in one chunk.
  Future<bool> _postWholeBundle(String id, List<int> envelope) async {
    try {
      final request = await _bulkHttp
          .postUrl(Uri.parse('$journeyHubUrl/bundle'))
          .timeout(const Duration(seconds: 15));
      request.headers.contentType = ContentType.json;
      request.contentLength = envelope.length;
      request.add(envelope);
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      final body = await response.transform(utf8.decoder).join();
      _note('bundle $id posted: ${response.statusCode} ${body.trim()}');
      return response.statusCode == 200;
    } on Object catch (error) {
      _note('bundle $id post failed: $error');
      return false;
    }
  }

  /// GET /have?id=: the chunk indexes the hub holds; null when it could not
  /// be asked.
  Future<List<int>?> _haveChunks(String id) async {
    try {
      final response = await _bulkHttp
          .getUrl(Uri.parse('$journeyHubUrl/have?id=$id'))
          .then((request) => request.close())
          .timeout(const Duration(seconds: 15));
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode != 200) {
        _note('have $id: ${response.statusCode} ${body.trim()}');
        return null;
      }
      final decoded = jsonDecode(body);
      if (decoded is! Map<String, Object?>) return null;
      final have = decoded['have'];
      if (have is! List) return null;
      return [
        for (final idx in have)
          if (idx is int) idx,
      ];
    } on Object catch (error) {
      _note('have $id failed: $error');
      return null;
    }
  }

  /// POST /chunk with the raw bytes: 8 KB is about 4 s on a 16 kbit/s gate,
  /// so the reply deadline is 30 s, not the probe's 4 s.
  Future<ChunkReply> _postChunk({
    required String id,
    required int idx,
    required int n,
    required String sha256,
    required List<int> bytes,
  }) async {
    try {
      final request = await _bulkHttp
          .postUrl(
            Uri.parse(
              '$journeyHubUrl/chunk?id=$id&idx=$idx&n=$n&sha256=$sha256',
            ),
          )
          .timeout(const Duration(seconds: 15));
      request.headers.contentType = ContentType.binary;
      request.contentLength = bytes.length;
      request.add(bytes);
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      final body = (await response.transform(utf8.decoder).join()).trim();
      if (response.statusCode != 200) {
        _note('chunk $id#$idx/$n: ${response.statusCode} $body');
        return ChunkReply.failed;
      }
      if (body.startsWith('complete')) {
        _note('chunk $id#$idx/$n: $body');
        return ChunkReply.complete;
      }
      return ChunkReply.stored;
    } on Object catch (error) {
      _note('chunk $id#$idx/$n failed: $error');
      return ChunkReply.failed;
    }
  }

  /// One cheap GET: the probe that decides whether a window is open.
  Future<bool> _hubReachable() async {
    try {
      final response = await _http
          .getUrl(Uri.parse('$journeyHubUrl/health'))
          .then((request) => request.close())
          .timeout(const Duration(seconds: 4));
      await response.drain<void>();
      return response.statusCode == 200;
    } on Object {
      return false;
    }
  }

  /// The queue's forwarder: the whole signed envelope in one POST; true only
  /// on a 200 so the queue keeps the bundle for the next window otherwise.
  Future<bool> _postBundle(DtnBundle bundle) async {
    try {
      final request = await _http
          .postUrl(Uri.parse('$journeyHubUrl/bundle'))
          .timeout(const Duration(seconds: 5));
      request.headers.contentType = ContentType.json;
      request.contentLength = bundle.payload.length;
      request.add(bundle.payload);
      final response = await request.close().timeout(
        const Duration(seconds: 15),
      );
      final body = await response.transform(utf8.decoder).join();
      _note('bundle ${bundle.id} posted: ${response.statusCode} $body');
      return response.statusCode == 200;
    } on Object catch (error) {
      _note('bundle ${bundle.id} post failed: $error');
      return false;
    }
  }

  static Future<RawRtcCounters?> _counters(E2eCallStack stack) async {
    final port = stack.port;
    if (port == null) return null;
    try {
      return await port.readStatsCounters().timeout(
        const Duration(seconds: 5),
        onTimeout: () => null,
      );
    } on StateError {
      return null; // closed under us: the call just ended
    }
  }
}

/// Why a parsed blackout plan cannot be served, or null when it can. The
/// error text is what the `failed` report carries. Two cases: no items
/// (v2 or v3), and a v3 plan whose stream map carries no usable port
/// (absent, 0, out of range, or not an int) — the flush would otherwise
/// return before writing a byte on every probe until lifetime_s expires.
String? blackoutPlanRejection(BlackoutPlan plan) {
  if (plan.items.isEmpty) return 'blackout v${plan.v} plan is empty';
  if (plan.v == 3 && BlackoutStreamParams.portOf(plan.stream) == null) {
    return 'blackout v3 plan carries no stream port';
  }
  return null;
}

/// The v2 forwarder's view of the hub: the three routes on the peer's
/// bulk client.
class _HubBlackoutTransport implements BlackoutTransport {
  _HubBlackoutTransport(this._peer);

  final JourneyPeer _peer;

  @override
  Future<bool> postWhole(String id, List<int> envelope) =>
      _peer._postWholeBundle(id, envelope);

  @override
  Future<List<int>?> have(String id) => _peer._haveChunks(id);

  @override
  Future<ChunkReply> postChunk({
    required String id,
    required int idx,
    required int n,
    required String sha256,
    required List<int> bytes,
  }) => _peer._postChunk(id: id, idx: idx, n: n, sha256: sha256, bytes: bytes);
}

/// The door's ordinary-traffic GET over dart:io.
///
/// Its own HttpClient, with a 3 s connect timeout and the dev certificate
/// accepted for the configured host ONLY — the rig's relay presents the
/// well-known dev certificate on the same address and port that serves this
/// page, and there is nothing here to protect. The body is drained so the
/// reported byte count is what actually arrived.
class _DoorHttpClient implements DoorHttpGetter {
  _DoorHttpClient(this.allowedHost);

  final String allowedHost;

  late final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 3)
    ..badCertificateCallback = (X509Certificate cert, String host, int port) =>
        host == allowedHost;

  @override
  Future<DoorHttpResponse> get(String url) async {
    final request = await _client
        .getUrl(Uri.parse(url))
        .timeout(const Duration(seconds: 5));
    final response = await request.close().timeout(const Duration(seconds: 10));
    var bytes = 0;
    await for (final chunk in response) {
      bytes += chunk.length;
    }
    return DoorHttpResponse(status: response.statusCode, bytes: bytes);
  }
}

/// The reset control over dart:io.
///
/// The distinction the whole control rests on is in the errno: an RST in
/// answer to a SYN arrives as ECONNREFUSED (61 on darwin), an RST on an
/// established connection as ECONNRESET (54). A DROP produces no answer at
/// all and surfaces as ETIMEDOUT (60) or a SocketException whose message
/// says the connect timed out — a different outcome, and not a pass.
class _DoorTcpConnector implements DoorTcpConnector {
  const _DoorTcpConnector();

  static const int _econnreset = 54;
  static const int _etimedout = 60;
  static const int _econnrefused = 61;

  @override
  Future<TcpProbeOutcome> connect({
    required String host,
    required int port,
    required Duration timeout,
  }) async {
    try {
      final socket = await Socket.connect(host, port, timeout: timeout);
      socket.destroy();
      return TcpProbeOutcome.connected;
    } on SocketException catch (error) {
      final code = error.osError?.errorCode;
      if (code == _econnrefused || code == _econnreset) {
        return TcpProbeOutcome.reset;
      }
      if (code == _etimedout ||
          error.message.toLowerCase().contains('timed out')) {
        return TcpProbeOutcome.timedOut;
      }
      return TcpProbeOutcome.error;
    } on TimeoutException {
      return TcpProbeOutcome.timedOut;
    }
  }
}

/// The QUIC control over dart:io: one 1200-byte Initial-shaped datagram out
/// of an ephemeral port, then silence for the whole timeout. Anything read
/// back — including an ICMP-driven error the socket surfaces — ends the
/// wait, because the control's claim is that NOTHING answers.
class _DoorUdpProber implements DoorUdpProber {
  const _DoorUdpProber();

  @override
  Future<UdpProbeOutcome> probe({
    required String host,
    required int port,
    required Duration timeout,
  }) async {
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    final answered = Completer<UdpProbeOutcome>();
    final subscription = socket.listen(
      (event) {
        if (answered.isCompleted) return;
        if (event == RawSocketEvent.read) {
          final datagram = socket.receive();
          if (datagram != null) answered.complete(UdpProbeOutcome.replied);
        }
      },
      onError: (Object _) {
        if (!answered.isCompleted) answered.complete(UdpProbeOutcome.replied);
      },
    );
    try {
      final address = (await InternetAddress.lookup(host)).first;
      socket.send(quicShapedInitialDatagram(), address, port);
      return await answered.future.timeout(
        timeout,
        onTimeout: () => UdpProbeOutcome.silent,
      );
    } on Object {
      return UdpProbeOutcome.error;
    } finally {
      await subscription.cancel();
      socket.close();
    }
  }
}

/// A connected dart:io socket as the stream lane's link: writes go to
/// the socket, the hub's bytes are the socket's own stream, destroy drops
/// the connection. A write error the socket reports later (on its done
/// future) is logged, not thrown: the lane already ended that session on
/// the stall, close, or error line it saw.
class _SocketLink implements StreamLink {
  _SocketLink(this._socket, {required this.log}) {
    _socket.done.then<void>(
      (_) {},
      onError: (Object error) => log('stream: socket closed: $error'),
    );
  }

  final Socket _socket;
  final void Function(String line) log;

  @override
  void write(List<int> bytes) => _socket.add(bytes);

  @override
  Stream<List<int>> get inbound => _socket;

  @override
  Future<void> destroy() async => _socket.destroy();
}

/// The receiving half of every lane, reporting each verified item.
class _Lanes {
  _Lanes(this._peer, this._stack, this._run);

  final JourneyPeer _peer;
  final E2eCallStack _stack;
  final String _run;

  ReliableMessenger? _messenger;
  Timer? _ticker;
  final AttachmentReceiver _attachments = AttachmentReceiver();
  StagedPhotoReceiver? _photos;
  VideoNoteReceiver? _videos;
  final List<StreamSubscription<Object?>> _subs = [];
  int texts = 0;
  int attachments = 0;
  int photos = 0;
  int videos = 0;

  /// Every /blob post fired so far, in receipt order; `drainBlobs` awaits
  /// them before the terminal report.
  final List<Future<bool>> _blobs = [];
  int blobsPosted = 0;
  int blobsFailed = 0;

  /// Fires one /blob post for a verified item and queues it. Never throws:
  /// this runs inside lane callbacks, and `_postBlob` swallows its errors.
  void _post(String kind, String id, List<int> bytes) {
    final posted = _peer._postBlob(run: _run, kind: kind, id: id, bytes: bytes);
    _blobs.add(
      posted.then((ok) {
        if (ok) {
          blobsPosted++;
        } else {
          blobsFailed++;
        }
        return ok;
      }),
    );
  }

  /// Waits for every queued /blob post, at most 30 s overall; never throws.
  /// A post still in flight at the cap counts as neither posted nor
  /// failed — the summary shows the gap against the item counts.
  Future<void> drainBlobs() async {
    if (_blobs.isEmpty) return;
    try {
      await Future.wait(_blobs).timeout(
        const Duration(seconds: 30),
        onTimeout: () {
          _peer._note(
            'blob drain timed out: posted=$blobsPosted failed=$blobsFailed '
            'of ${_blobs.length}',
          );
          return const <bool>[];
        },
      );
    } on Object catch (error) {
      _peer._note('blob drain error=$error');
    }
  }

  Future<void> open() async {
    final chatPort = MediaChannelDataPort(
      await _stack.media.openDataChannel(CallLanes.chat),
    );
    final photoPort = MediaChannelDataPort(
      await _stack.media.openDataChannel(CallLanes.photo),
      maxPendingFrames: 128,
    );
    final videoPort = MediaChannelDataPort(
      await _stack.media.openDataChannel(CallLanes.video),
      maxPendingFrames: 128,
    );
    final messenger = _messenger = ReliableMessenger(chatPort, peerId: 'phone');
    _ticker = Timer.periodic(const Duration(milliseconds: 500), (_) {
      unawaited(messenger.tick());
    });
    final photoRx = _photos = StagedPhotoReceiver.arq(photoPort);
    final videoRx = _videos = VideoNoteReceiver(videoPort);

    _subs.add(
      messenger.incoming.listen((message) {
        if (photoRx.offerText(message.text)) return;
        if (videoRx.offerText(message.text)) return;
        if (_attachments.offer(message.text)) return;
        texts++;
        _peer._note('text id=${message.id} "${message.text}"');
        unawaited(
          _peer._report('text', <String, Object?>{
            'id': message.id,
            'text': message.text,
            'sha256': contentSha256Hex(utf8.encode(message.text)),
          }, run: _run),
        );
        // The app shows the reply as an incoming bubble on the recording.
        unawaited(messenger.send('echo: ${message.text}'));
      }),
    );
    _subs.add(
      _attachments.completed.listen((attachment) {
        attachments++;
        final sha = contentSha256Hex(attachment.bytes);
        _peer._note(
          'attachment id=${attachment.id} kind=${attachment.kind.name} '
          'bytes=${attachment.bytes.length} sha256=$sha',
        );
        unawaited(
          _peer._report('attachment', <String, Object?>{
            'id': attachment.id,
            'kind': attachment.kind.name,
            'content_type': attachment.contentType,
            'bytes': attachment.bytes.length,
            'sha256': sha,
            'verified': true, // chunk reassembly is complete; sha reported
          }, run: _run),
        );
        // A voice note is an audio attachment; anything else is a file.
        _post(
          attachment.contentType.startsWith('audio/') ? 'voice' : 'file',
          attachment.id,
          attachment.bytes,
        );
      }),
    );
    _subs.add(
      photoRx.updates.listen((update) {
        final original = update.state.original;
        _peer._note(
          'photo id=${update.photoId} stage=${update.stage.name} '
          'verified=${update.state.sha256Verified}',
        );
        if (update.stage != PhotoStage.originalVerified) return;
        photos++;
        unawaited(
          _peer._report('photo', <String, Object?>{
            'id': update.photoId,
            'stage': update.stage.name,
            'bytes': original?.length,
            'sha256': update.state.announcement.sha256Hex,
            'verified': update.state.sha256Verified,
            'deduplicated': update.deduplicated,
          }, run: _run),
        );
        // Only the verified original goes to /blob — the preview stage
        // carries different bytes and would break the Mac's sha chain.
        if (original == null) {
          _peer._note('photo id=${update.photoId} verified without bytes');
          return;
        }
        _post('photo', update.photoId, original);
      }),
    );
    _subs.add(
      videoRx.updates.listen((update) {
        _peer._note('video id=${update.videoId} stage=${update.stage.name}');
        if (update.stage == VideoNoteStage.announced) return;
        if (update.stage == VideoNoteStage.verified) videos++;
        unawaited(
          _peer._report('video', <String, Object?>{
            'id': update.videoId,
            'stage': update.stage.name,
            'bytes': update.state.bytes?.length,
            'sha256': update.state.announcement.sha256Hex,
            'verified': update.stage == VideoNoteStage.verified,
          }, run: _run),
        );
        if (update.stage != VideoNoteStage.verified) return;
        final bytes = update.state.bytes;
        if (bytes == null) {
          _peer._note('video id=${update.videoId} verified without bytes');
          return;
        }
        _post('video', update.videoId, bytes);
      }),
    );
  }

  Map<String, Object?> summary() => <String, Object?>{
    'texts': texts,
    'attachments': attachments,
    'photos': photos,
    'videos': videos,
    'blobs_posted': blobsPosted,
    'blobs_failed': blobsFailed,
  };

  Future<void> close() async {
    _ticker?.cancel();
    for (final sub in _subs) {
      await sub.cancel();
    }
    _subs.clear();
    await _photos?.close();
    await _videos?.close();
    await _messenger?.close();
  }
}

class JourneyPeerApp extends StatelessWidget {
  const JourneyPeerApp(this.peer, {super.key});

  final JourneyPeer peer;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Journey peer',
      theme: ThemeData.dark(useMaterial3: true),
      home: Scaffold(
        appBar: AppBar(title: const Text('Journey peer (phone side)')),
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ValueListenableBuilder<String>(
                valueListenable: peer.status,
                builder: (context, value, _) =>
                    Text(value, style: Theme.of(context).textTheme.titleLarge),
              ),
              const SizedBox(height: 12),
              ValueListenableBuilder<String>(
                valueListenable: peer.letter,
                builder: (context, value, _) => value.isEmpty
                    ? const SizedBox.shrink()
                    : ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 160),
                        child: SingleChildScrollView(
                          child: SelectableText(
                            value,
                            key: const Key('journey-peer-letter'),
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                        ),
                      ),
              ),
              const SizedBox(height: 12),
              // Typed before the run; carried when the job says the phone
              // writes the letter. TextField owns its controller, so a plain
              // notifier is enough and nothing needs disposing.
              TextField(
                key: const Key('journey-peer-draft'),
                maxLines: 3,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  labelText: 'Letter from this phone (chat_source: phone)',
                ),
                onChanged: (value) => peer.draft.value = value,
                onSubmitted: (_) => peer.submitLetter(),
              ),
              const SizedBox(height: 8),
              ValueListenableBuilder<VoiceAlert?>(
                valueListenable: peer.voiceAlert,
                builder: (context, alert, _) => alert == null
                    ? const SizedBox.shrink()
                    : _VoiceAlertBanner(
                        alert: alert,
                        onDismiss: peer.dismissVoiceAlert,
                      ),
              ),
              ValueListenableBuilder<bool>(
                valueListenable: peer.letterWanted,
                builder: (context, wanted, _) => Row(
                  children: [
                    Expanded(
                      child: SizedBox(
                        height: 56,
                        child: FilledButton(
                          key: const Key('journey-peer-send'),
                          onPressed: wanted ? peer.submitLetter : null,
                          child: const Text('Send letter'),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _RecordButton(peer: peer, wanted: wanted),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: ValueListenableBuilder<List<String>>(
                  valueListenable: peer.events,
                  builder: (context, lines, _) => ListView(
                    reverse: true,
                    children: [
                      for (final line in lines.reversed)
                        Text(
                          line,
                          style: const TextStyle(
                            fontFamily: 'Menlo',
                            fontSize: 12,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The one failure surface for recording. Large, coloured, in the person's
/// hand next to the button that caused it, and gone only when they tap
/// "Got it" — an entry in the scrolling event list below is not something a
/// person mid-task reads.
class _VoiceAlertBanner extends StatelessWidget {
  const _VoiceAlertBanner({required this.alert, required this.onDismiss});

  final VoiceAlert alert;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final tone = alert.isError
        ? const Color(0xFFB3261E)
        : const Color(0xFF1B5E20);
    return Container(
      key: const Key('journey-peer-voice-alert'),
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: tone,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                alert.isError ? Icons.mic_off : Icons.check_circle,
                color: Colors.white,
                size: 28,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  alert.message,
                  key: const Key('journey-peer-voice-alert-text'),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 48,
            child: FilledButton(
              key: const Key('journey-peer-voice-alert-dismiss'),
              style: FilledButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: tone,
              ),
              onPressed: onDismiss,
              child: const Text('Got it'),
            ),
          ),
        ],
      ),
    );
  }
}

/// Record / Stop, drawn from [JourneyPeer.recordState] alone: one look says
/// which of the five states it is in, and the live one counts against the
/// cap so nobody has to guess whether the microphone is open.
class _RecordButton extends StatelessWidget {
  const _RecordButton({required this.peer, required this.wanted});

  final JourneyPeer peer;
  final bool wanted;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<VoiceRecordState>(
      valueListenable: peer.recordState,
      builder: (context, state, _) => ValueListenableBuilder<Duration>(
        valueListenable: peer.recordElapsed,
        builder: (context, elapsed, _) {
          final busy =
              state == VoiceRecordState.starting ||
              state == VoiceRecordState.stopping;
          final live = state == VoiceRecordState.recording;
          final done = state == VoiceRecordState.recorded;
          return SizedBox(
            height: 56,
            child: FilledButton(
              key: const Key('journey-peer-record'),
              style: FilledButton.styleFrom(
                backgroundColor: live
                    ? const Color(0xFFB3261E)
                    : done
                    ? const Color(0xFF1B5E20)
                    : null,
                foregroundColor: live || done ? Colors.white : null,
              ),
              onPressed: wanted && !busy ? peer.toggleRecording : null,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(live ? Icons.stop_circle : Icons.mic, size: 22),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      voiceRecordButtonLabel(state, elapsed),
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
