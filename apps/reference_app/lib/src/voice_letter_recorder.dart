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
import 'dart:typed_data';

// hamseda_codec has no public barrel exporting these two files (its own
// package:hamseda_codec/hamseda_codec.dart is an unrelated token codec);
// integration_test/e2e_matrix_test.dart already imports them the same way.
// ignore: implementation_imports
import 'package:hamseda_codec/src/codec2_ffi.dart';
// ignore: implementation_imports
import 'package:hamseda_codec/src/voice_note_codec.dart';
import 'package:record/record.dart';

/// The hard cap on one recording. The DNS-valve cap (4096 B) allows more
/// than this at 700C, but 30 s is what was asked for and is plenty for a
/// short letter — a longer cap is a deliberate future decision, not an
/// oversight.
const Duration voiceLetterMaxLength = Duration(seconds: 30);

/// Thrown when the microphone cannot be opened (permission denied, or no
/// input device). The caller falls back to the typed-letter path.
class VoiceLetterUnavailable implements Exception {
  final String reason;
  VoiceLetterUnavailable(this.reason);
  @override
  String toString() => 'VoiceLetterUnavailable($reason)';
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

/// One recording session: `start()` then `stop()`. Not reusable — make a
/// fresh instance per attempt.
class VoiceLetterRecorder {
  final AudioRecorder _recorder = AudioRecorder();
  StreamSubscription<Uint8List>? _sub;
  final BytesBuilder _pcm = BytesBuilder(copy: false);
  DateTime? _startedAt;
  Timer? _capTimer;
  Completer<void>? _stopped;

  /// Opens the microphone and starts accumulating 8 kHz mono PCM16. Throws
  /// [VoiceLetterUnavailable] if permission is refused. Arms a 30 s timer
  /// that calls [stop] on its own — the caller does not have to enforce the
  /// cap itself, but MUST still await [stop] once (directly, or by letting
  /// the timer's own call run) to release the recorder.
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
        noiseSuppress: false,
        autoGain: false,
      ),
    );
    _startedAt = DateTime.now();
    _sub = stream.listen(_pcm.add);
    _capTimer = Timer(voiceLetterMaxLength, () {
      // Fire-and-forget: a caller already mid-`stop()` just sees this as a
      // no-op via `_stopped`.
      unawaited(stop());
    });
  }

  /// Stops recording, encodes what was captured, and returns the letter —
  /// or null if the capture was too short or came in at the wrong rate (a
  /// refusal, not a crash: the caller falls back to text). Safe to call
  /// more than once; the second call returns null immediately.
  Future<VoiceLetter?> stop() async {
    if (_stopped != null) return null;
    final done = _stopped = Completer<void>();
    _capTimer?.cancel();
    _capTimer = null;
    try {
      await _sub?.cancel();
      _sub = null;
      await _recorder.stop();
      _recorder.dispose();
      final startedAt = _startedAt;
      if (startedAt == null) return null;
      final elapsed = DateTime.now().difference(startedAt);
      final pcm = _pcm.takeBytes();
      // Rate guard: 8 kHz * 2 bytes/sample = 16 000 B/s, expected. A plugin
      // that silently delivered a different rate would still hand Codec2
      // valid-looking bytes and produce noise that passes every existing
      // witness (sha256, chunk count) — this is what catches that instead
      // of trusting the config was honoured.
      final expected = elapsed.inMilliseconds * 16;
      final within = expected == 0
          ? false
          : (pcm.length - expected).abs() <= expected * 0.10;
      if (elapsed < const Duration(seconds: 1) || !within) return null;
      final codec = Codec2(codec2Mode700C);
      try {
        final samples = pcm.buffer.asInt16List(0, pcm.length ~/ 2);
        final perFrame = codec.samplesPerFrame;
        final frameCount = samples.length ~/ perFrame;
        final frames = <Uint8List>[
          for (var i = 0; i < frameCount; i++)
            codec.encodeFrame(
              samples.sublist(i * perFrame, (i + 1) * perFrame),
            ),
        ];
        final wire = packVoiceNote(frames: frames, mode: VoiceNoteMode.c700);
        return VoiceLetter(
          wire: wire,
          frames: frames.length,
          length: Duration(milliseconds: frames.length * 40),
          pcmBytes: pcm.length,
          elapsed: elapsed,
        );
      } finally {
        codec.dispose();
      }
    } finally {
      done.complete();
    }
  }
}
