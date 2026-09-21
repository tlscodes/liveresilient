/// Records up to 30 s from this device's microphone and encodes it as a
/// Codec2 700C voice letter — an alternative to a typed letter on the same
/// `chat_source: phone` DNS-valve path (journey_peer_app.dart). 30 s at
/// 87.5 B/s (packVoiceNote's tight packing) is about 2.6 KB, comfortably
/// under the lane's 4096-byte cap; this class never produces more than that
/// by construction (the recording itself is hard-capped at 30 s).
///
/// Kept out of journey_peer_app.dart on purpose: the class is shaped to
/// later serve `MyApp.voiceNoteSource` (lib/main.dart) too, which is
/// separate, deferred work — wiring it there is not done here.
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

// hamseda_codec has no public barrel exporting these two files (its own
// package:hamseda_codec/hamseda_codec.dart is an unrelated token codec);
// integration_test/e2e_matrix_test.dart already imports them the same way.
// ignore: implementation_imports
import 'package:hamseda_codec/src/codec2_ffi.dart';
// ignore: implementation_imports
import 'package:hamseda_codec/src/voice_note_codec.dart';
import 'package:record/record.dart';

/// The hard cap on one recording. Since 2026-09-21 a letter over the
/// door's 4096 B rides as up to ten letters (letter_parts.dart, 40670 B),
/// and Codec2 700C costs about 88 B/s on the rig (2626 B for 30 s, session
/// MDB52T): five minutes is about 26 KB, seven letters, with room to spare.
/// The cap per letter is untouched.
const Duration voiceLetterMaxLength = Duration(minutes: 5);

/// What thirty letters carry (letter_parts.dart: 30 x (4096 - 29)), the
/// budget the recorder picks its Codec2 mode against: 3200 for five
/// minutes is ~120 KB and fits.
const int voiceLetterBudgetBytes = 30 * (4096 - 29);

/// Which 20 ms frames of [x] hold speech: an adaptive floor (the running
/// 5th percentile of frame RMS, never under 30), a threshold 8 dB above
/// it, two frames of pre-roll and eight of hangover. The first cut of this
/// file normalized BEFORE gating and lifted a -38 dBFS room-noise take by
/// 18 dB into clipping; Codec2 then hallucinated voicing on clipped noise
/// (measured 2026-09-21). Gate first, always.
List<bool> speechMask(Int16List x, {int frame = 160}) {
  final n = x.length ~/ frame;
  if (n == 0) return const [];
  final rms = List<double>.generate(n, (i) {
    var e = 0.0;
    for (var k = i * frame; k < (i + 1) * frame; k++) {
      e += x[k] * x[k].toDouble();
    }
    return math.sqrt(e / frame);
  });
  final sorted = [...rms]..sort();
  final floor = math.max(sorted[(n * 0.05).floor()], 30.0);
  final thr = floor * 2.5; // +8 dB
  final mask = List<bool>.filled(n, false);
  var hang = 0;
  for (var i = 0; i < n; i++) {
    if (rms[i] > thr) {
      hang = 8;
      for (var p = math.max(0, i - 2); p <= i; p++) {
        mask[p] = true;
      }
    } else if (hang > 0) {
      hang--;
      mask[i] = true;
    }
  }
  return mask;
}

/// True when at least a tenth of the frames are speech and that speech
/// sits above -45 dBFS. A take that fails this is refused (noSpeech).
bool hasSpeech(Int16List x, {int frame = 160}) {
  final mask = speechMask(x, frame: frame);
  if (mask.isEmpty) return false;
  final voiced = mask.where((m) => m).length;
  if (voiced < mask.length * 0.10) return false;
  var e = 0.0;
  var count = 0;
  for (var i = 0; i < mask.length; i++) {
    if (!mask[i]) continue;
    for (var k = i * frame; k < (i + 1) * frame; k++) {
      e += x[k] * x[k].toDouble();
      count++;
    }
  }
  final rms = math.sqrt(e / math.max(count, 1));
  return rms >= 32768 * 0.0056; // -45 dBFS
}

/// DC removal, a one-pole 80 Hz high-pass, then a gain computed from the
/// SPEECH frames only (RMS to about -20 dBFS) and limited so the loudest
/// peak stays under 0.9 full scale; non-speech frames are attenuated by
/// 20 dB (Codec2 decodes near-silence cleanly and has no comfort noise).
/// Pure Dart, 8 kHz mono. Call [hasSpeech] first; this does not refuse.
Int16List normalizeSpeech(Int16List x, {int frame = 160}) {
  if (x.isEmpty) return x;
  var mean = 0.0;
  for (final s in x) {
    mean += s;
  }
  mean /= x.length;
  final hp = Float64List(x.length);
  var xPrev = 0.0, yPrev = 0.0;
  for (var i = 0; i < x.length; i++) {
    final v = x[i] - mean;
    final y = v - xPrev + 0.94 * yPrev;
    hp[i] = y;
    xPrev = v;
    yPrev = y;
  }
  final mask = speechMask(x, frame: frame);
  var e = 0.0;
  var count = 0;
  var peak = 1.0;
  for (var i = 0; i < mask.length; i++) {
    for (var k = i * frame; k < (i + 1) * frame; k++) {
      final a = hp[k].abs();
      if (a > peak) peak = a;
      if (mask[i]) {
        e += hp[k] * hp[k];
        count++;
      }
    }
  }
  final rmsSpeech = math.sqrt(e / math.max(count, 1));
  final gain = math
      .min(0.1 * 32768 / math.max(rmsSpeech, 1.0), 0.9 * 32767 / peak)
      .clamp(0.25, 8.0);
  final out = Int16List(x.length);
  for (var i = 0; i < x.length; i++) {
    final f = i ~/ frame;
    final g = (f < mask.length && !mask[f]) ? gain * 0.1 : gain;
    out[i] = (hp[i] * g).round().clamp(-32768, 32767);
  }
  return out;
}

/// Thrown when the microphone cannot be opened (permission denied, or no
/// input device). The caller falls back to the typed-letter path.
class VoiceLetterUnavailable implements Exception {
  final String reason;
  VoiceLetterUnavailable(this.reason);
  @override
  String toString() => 'VoiceLetterUnavailable($reason)';
}

/// Why a recording produced no letter. A refusal is never a crash — the
/// caller falls back to text — but the person holding the phone is told
/// which one it was, in those words, instead of one lumped sentence.
enum VoiceLetterRefusal {
  /// [VoiceLetterRecorder.stop] ran without a successful
  /// [VoiceLetterRecorder.start]: nothing was ever captured.
  notStarted,

  /// Under one second of wall clock — a tap-tap, not a letter.
  tooShort,

  /// The microphone delivered a byte count the configured 8 kHz mono PCM16
  /// rate cannot explain (more than 10 % off). Encoding it would produce
  /// noise that still passes every digest witness, so it is refused.
  offRate,

  /// Teardown or encoding threw; the text is in
  /// [VoiceLetterRecorder.stopError].
  failed,

  /// The take holds no speech: under a tenth of its frames rise above the
  /// noise floor, or the speech itself sits below -45 dBFS. Codec2 turns
  /// such a take into buzz that passes every digest witness (measured on
  /// the rig 2026-09-21: a room-noise take at -38 dBFS), so it is refused.
  noSpeech,
}

/// One successfully recorded and encoded voice letter.
class VoiceLetter {
  const VoiceLetter({
    required this.wire,
    required this.frames,
    required this.length,
    required this.pcmBytes,
    required this.elapsed,
  });

  /// The bit-packed Codec2 700C payload (voice_note_codec.dart's wire
  /// format) — this is what rides the DNS-valve lane, opaque bytes exactly
  /// like a typed letter's UTF-8.
  final Uint8List wire;

  /// How many 40 ms frames were encoded.
  final int frames;

  /// The encoded length (frames * 40 ms) — may be a little short of
  /// [elapsed] because a trailing partial frame is dropped, never padded.
  final Duration length;

  /// Raw PCM byte count captured, before encoding — kept for the rate
  /// guard's evidence (the `lane` event carries it).
  final int pcmBytes;

  /// Wall-clock time the recording actually ran.
  final Duration elapsed;
}

/// What a caller needs from one recording session, so the phone peer can be
/// driven in a unit test without a microphone. [VoiceLetterRecorder] is the
/// only implementation that touches real audio.
abstract class VoiceRecording {
  /// Called when the [voiceLetterMaxLength] cap stops the recording on its
  /// own, with the letter that recording produced — never a discarded one.
  /// `null` means the cap-stopped take was refused; [refusal] says why.
  void Function(VoiceLetter? letter, VoiceLetterRefusal? refusal)? onCapReached;

  /// Opens the microphone. Throws [VoiceLetterUnavailable] when it cannot.
  Future<void> start();

  /// Stops, encodes, and returns the letter — or null with [refusal] set.
  /// Never throws, and every caller of a finished recording gets the same
  /// answer as the first one.
  Future<VoiceLetter?> stop();

  /// How long the recording has run; keeps ticking until [stop], frozen
  /// afterwards. Zero before [start].
  Duration get elapsed;

  /// Set when [stop] returned null.
  VoiceLetterRefusal? get refusal;

  /// Raw PCM bytes the microphone delivered, known once [stop] has run.
  int get pcmBytes;

  /// The error text behind [VoiceLetterRefusal.failed].
  String? get stopError;
}

/// One recording session: `start()` then `stop()`. Not reusable — make a
/// fresh instance per attempt.
class VoiceLetterRecorder implements VoiceRecording {
  @override
  void Function(VoiceLetter? letter, VoiceLetterRefusal? refusal)? onCapReached;

  final AudioRecorder _recorder = AudioRecorder();
  StreamSubscription<Uint8List>? _sub;
  final BytesBuilder _pcm = BytesBuilder(copy: false);
  DateTime? _startedAt;
  DateTime? _endedAt;
  Timer? _capTimer;
  Completer<VoiceLetter?>? _stopped;
  VoiceLetterRefusal? _refusal;
  String? _stopError;
  int _pcmBytes = 0;

  @override
  Duration get elapsed {
    final startedAt = _startedAt;
    if (startedAt == null) return Duration.zero;
    return (_endedAt ?? DateTime.now()).difference(startedAt);
  }

  @override
  VoiceLetterRefusal? get refusal => _refusal;

  @override
  int get pcmBytes => _pcmBytes;

  @override
  String? get stopError => _stopError;

  /// Opens the microphone and starts accumulating 8 kHz mono PCM16. Throws
  /// [VoiceLetterUnavailable] if permission is refused. Arms a 30 s timer
  /// that calls [stop] on its own and hands the result to [onCapReached] —
  /// the caller does not have to enforce the cap itself, and a recording
  /// the cap closed is a finished letter, not a lost one.
  @override
  Future<void> start() async {
    if (!await _recorder.hasPermission()) {
      throw VoiceLetterUnavailable('microphone permission not granted');
    }
    final stream = await _recorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 8000,
        numChannels: 1,
        echoCancel: false,
        // Apple's voice-processing noise suppression: the cheapest quality
        // win for a close-mic codec like Codec2 (2026-09-21).
        noiseSuppress: true,
        autoGain: false,
      ),
    );
    _startedAt = DateTime.now();
    _sub = stream.listen(_pcm.add);
    _capTimer = Timer(voiceLetterMaxLength, () async {
      // The cap HANDS OVER its letter. Until 2026-09-17 this call was a
      // bare `unawaited(stop())`: every recording that ran past 30 s was
      // encoded, dropped on the floor, and the caller's later stop() —
      // seeing the session already closed — returned null, which the phone
      // reported to the person as "too short". That is the whole reason no
      // live take longer than 2.4 s has ever been carried.
      final letter = await stop();
      onCapReached?.call(letter, _refusal);
    });
  }

  /// Stops recording, encodes what was captured, and returns the letter —
  /// or null if the capture was too short, came in at the wrong rate, or
  /// the teardown threw ([refusal] says which; [stopError] carries the
  /// text). Safe to call more than once: every later call returns exactly
  /// what the first one produced, so whoever asks last still gets the
  /// letter.
  @override
  Future<VoiceLetter?> stop() async {
    final pending = _stopped;
    if (pending != null) return pending.future;
    final done = _stopped = Completer<VoiceLetter?>();
    // Wall clock is read HERE, before the teardown round-trips to the
    // platform. Reading it after `await _recorder.stop()` charged that
    // round-trip (tens to hundreds of ms) to the recording, inflating the
    // expected byte count and pushing short takes out of the rate guard's
    // 10 % band for no reason of the person's making.
    final endedAt = _endedAt = DateTime.now();
    _capTimer?.cancel();
    _capTimer = null;
    VoiceLetter? letter;
    try {
      await _sub?.cancel();
      _sub = null;
      await _recorder.stop();
      _recorder.dispose();
      final startedAt = _startedAt;
      if (startedAt == null) {
        _refusal = VoiceLetterRefusal.notStarted;
      } else {
        final elapsed = endedAt.difference(startedAt);
        final pcm = _pcm.takeBytes();
        _pcmBytes = pcm.length;
        // Rate guard: 8 kHz * 2 bytes/sample = 16 000 B/s, expected. A
        // plugin that silently delivered a different rate would still hand
        // Codec2 valid-looking bytes and produce noise that passes every
        // existing witness (sha256, chunk count) — this is what catches
        // that instead of trusting the config was honoured.
        final expected = elapsed.inMilliseconds * 16;
        final within = expected == 0
            ? false
            : (pcm.length - expected).abs() <= expected * 0.10;
        if (elapsed < const Duration(seconds: 1)) {
          _refusal = VoiceLetterRefusal.tooShort;
        } else if (!within) {
          _refusal = VoiceLetterRefusal.offRate;
        } else if (!hasSpeech(
          Int16List.sublistView(pcm, 0, pcm.length - pcm.length % 2),
        )) {
          _refusal = VoiceLetterRefusal.noSpeech;
        } else {
          letter = _encode(pcm, elapsed);
        }
      }
    } on Object catch (error) {
      // A refusal, not a crash: the caller falls back to text and the
      // person is told what threw instead of watching a silent no-op.
      _refusal = VoiceLetterRefusal.failed;
      _stopError = '$error';
      letter = null;
    } finally {
      done.complete(letter);
    }
    return letter;
  }

  VoiceLetter _encode(Uint8List pcm, Duration elapsed) {
    // sublistView, not buffer.asInt16List: the latter ignores the
    // builder's offsetInBytes and would read a neighbouring chunk's bytes
    // as audio without any of the witnesses noticing.
    final raw = Int16List.sublistView(pcm, 0, pcm.length - pcm.length % 2);
    // Codec2's pitch/LPC stages are trained on level-normalized speech:
    // remove DC, pass 80 Hz, bring the take to about -20 dBFS.
    final samples = normalizeSpeech(raw);
    // The best mode whose wire fits the letters (2026-09-21): 3200 for
    // anything up to five minutes within thirty letters; the mode rides
    // the wire's own nibble, so every receiver decodes what was sent.
    final mode = VoiceNoteMode.pick(
      Duration(milliseconds: samples.length ~/ 8),
      voiceLetterBudgetBytes,
    );
    final codec = Codec2(mode.codec2Mode);
    try {
      final perFrame = codec.samplesPerFrame;
      final frameCount = samples.length ~/ perFrame;
      final frames = <Uint8List>[
        for (var i = 0; i < frameCount; i++)
          codec.encodeFrame(samples.sublist(i * perFrame, (i + 1) * perFrame)),
      ];
      final wire = packVoiceNote(frames: frames, mode: mode);
      return VoiceLetter(
        wire: wire,
        frames: frames.length,
        length: Duration(milliseconds: frames.length * mode.frameMs),
        pcmBytes: pcm.length,
        elapsed: elapsed,
      );
    } finally {
      codec.dispose();
    }
  }
}
