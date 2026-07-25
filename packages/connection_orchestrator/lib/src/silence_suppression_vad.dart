/// Voice activity detection with silence suppression for the token-voice
/// lane. Real conversations are roughly half pauses; frames classified as
/// silence are not sent to the codec at all, so the byte budget of a
/// restricted path is spent only on actual speech. During a silent
/// stretch a tiny 2-byte keep-alive ping goes out once per second so the
/// receiving end (and any NAT binding on the path) knows the call is
/// still up.
///
/// Classification per frame, from two cheap features:
/// - RMS energy of the PCM samples — voiced speech is loud;
/// - zero-crossing rate (ZCR) — unvoiced consonants (s, f, sh) are quiet
///   but cross zero far more often than room noise, so a moderate-energy
///   high-ZCR frame still counts as speech.
///
/// A hangover keeps a few frames after the last detected speech so word
/// endings are not clipped.
///
/// Steady-state processing allocates nothing: `isSpeech` touches only
/// scalar locals, and the keep-alive ping is a single cached buffer
/// returned by reference.
library;

import 'dart:math';
import 'dart:typed_data';

/// What the caller should do with the current frame.
enum VadAction {
  /// Frame contains speech (or hangover): encode and send it.
  send,

  /// Silent frame inside the keep-alive interval: send nothing.
  drop,

  /// Silent frame, and a second has passed since the last transmission:
  /// send [SilenceSuppressionVAD.keepAlivePing] instead of audio.
  keepAlive,
}

/// Energy + zero-crossing voice activity detector with a hangover and a
/// once-per-second keep-alive during silence.
class SilenceSuppressionVAD {
  SilenceSuppressionVAD({
    this.rmsThreshold = 500.0,
    this.zcrSpeechRate = 0.15,
    this.quietFactor = 0.4,
    this.hangoverFrames = 5,
    this.keepAliveIntervalMs = 1000,
  })  : assert(rmsThreshold > 0),
        assert(zcrSpeechRate > 0 && zcrSpeechRate < 1),
        assert(quietFactor > 0 && quietFactor <= 1),
        assert(hangoverFrames >= 0),
        assert(keepAliveIntervalMs > 0);

  /// RMS level (in 16-bit sample units) at or above which a frame is
  /// speech regardless of ZCR. Raise to desensitize in noisy rooms.
  final double rmsThreshold;

  /// Fraction of sample pairs that must cross zero for a quieter frame
  /// to still count as speech (captures unvoiced consonants).
  final double zcrSpeechRate;

  /// A frame whose RMS is at least `quietFactor * rmsThreshold` may be
  /// promoted to speech by a high ZCR; below that it is always silence.
  final double quietFactor;

  /// Frames kept as speech after the last frame that measured as speech,
  /// so word endings are not clipped.
  final int hangoverFrames;

  /// Minimum spacing between keep-alive pings during silence.
  final int keepAliveIntervalMs;

  /// The 2-byte ping sent during silence. A fixed magic pair the
  /// receiver can tell apart from any sliding-window datagram (which is
  /// always >= 4 bytes). Cached — always the same instance.
  static final Uint8List keepAlivePing = Uint8List.fromList([0xA5, 0x5A]);

  int _hangoverLeft = 0;
  int _lastTransmitMs = -1 << 40;

  /// Frames classified as speech (before hangover), for diagnostics.
  int speechFrames = 0;

  /// Frames classified as silence, for diagnostics.
  int silenceFrames = 0;

  /// True when [pcmBuffer] measures as speech by energy or by the
  /// moderate-energy/high-ZCR rule. Pure measurement — no hangover, no
  /// keep-alive state; allocation-free.
  bool isSpeech(Int16List pcmBuffer) {
    if (pcmBuffer.isEmpty) return false;
    var energy = 0.0;
    var crossings = 0;
    var prev = pcmBuffer[0];
    for (var i = 0; i < pcmBuffer.length; i++) {
      final s = pcmBuffer[i];
      energy += s.toDouble() * s.toDouble();
      if ((s >= 0) != (prev >= 0)) crossings++;
      prev = s;
    }
    final rms = sqrt(energy / pcmBuffer.length);
    if (rms >= rmsThreshold) return true;
    if (rms >= rmsThreshold * quietFactor &&
        crossings / pcmBuffer.length >= zcrSpeechRate) {
      return true;
    }
    return false;
  }

  /// Classifies [pcmBuffer] and applies hangover + keep-alive pacing.
  /// [nowMs] is the caller's clock for this frame (monotonic).
  VadAction process(Int16List pcmBuffer, int nowMs) {
    if (isSpeech(pcmBuffer)) {
      speechFrames++;
      _hangoverLeft = hangoverFrames;
      _lastTransmitMs = nowMs;
      return VadAction.send;
    }
    silenceFrames++;
    if (_hangoverLeft > 0) {
      _hangoverLeft--;
      _lastTransmitMs = nowMs;
      return VadAction.send;
    }
    if (nowMs - _lastTransmitMs >= keepAliveIntervalMs) {
      _lastTransmitMs = nowMs;
      return VadAction.keepAlive;
    }
    return VadAction.drop;
  }
}
