/// Records one clip with this device's camera and turns it into a video
/// letter that fits thirty letters — the fourth way to author a letter on
/// the phone, beside a typed draft, a voice take and a photo, on the same
/// `chat_source: phone` path in journey_peer_app.dart (2026-09-21).
///
/// Three steps, each its own failure in plain words: the system camera
/// records up to [videoLetterMaxLength] (`image_picker`, no new plugin);
/// the Runner's `readVideoLetterSource` (AppDelegate.swift) scales it onto
/// the letter's 144x256 frame at 6 fps and mixes the audio down to 8 kHz;
/// and the vendored SVT-AV1 encodes it over FFI on a worker isolate, crf
/// bisected until the whole wire — Opus 6k audio tail included — fits
/// (broadcast_media's av1_encoder.dart). The wire is the same 'V1' wire the
/// Mac's make_video_letter.sh writes, so the Mac's open_video_letter.sh and
/// the peer's own dav1d decode read it unchanged.
///
/// Kept out of journey_peer_app.dart like the recorder and the picker:
/// [VideoSelection] is the seam a unit test drives with no camera.
library;

import 'dart:io';

// ignore: implementation_imports
import 'package:broadcast_media/src/av1_encoder.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import 'letter_parts.dart';
import 'photo_letter_picker.dart' show photoLetterFallbackChannel;

/// The hard cap on one clip: thirty letters carry 30 s at 144x256@6 with
/// Opus audio (the Mac's measured row, 121699 B of 122010).
const Duration videoLetterMaxLength = Duration(seconds: 30);

/// A human-readable size, shared with the photo button.
String videoLetterSize(int bytes) =>
    bytes < 1024 ? '$bytes B' : '${(bytes / 1024).toStringAsFixed(1)} KB';

/// Thrown when the camera cannot be opened (permission denied, no camera).
class VideoLetterUnavailable implements Exception {
  final String reason;
  VideoLetterUnavailable(this.reason);
  @override
  String toString() => 'VideoLetterUnavailable($reason)';
}

/// Why a take produced no letter. A refusal is never a crash — the caller
/// falls back to the other letters — but the person is told which one.
enum VideoLetterRefusal {
  /// The camera opened and the person backed out without recording.
  cancelled,

  /// The clip could not be read (no video track, reader failed).
  unreadable,

  /// Even at crf 63 the clip did not fit thirty letters.
  tooLong,

  /// The reader or the encoder threw; the text is in [VideoSelection.error].
  failed,
}

/// One clip, encoded, ready to ride the lane as opaque bytes.
class VideoLetter {
  const VideoLetter({
    required this.wire,
    required this.frames,
    required this.fps,
    required this.crf,
    required this.audioPackets,
    required this.passes,
    required this.encodeMs,
  });

  /// The 'V1' wire — this is the payload.
  final Uint8List wire;
  final int frames;
  final int fps;
  final int crf;
  final int audioPackets;
  final int passes;
  final int encodeMs;

  Duration get length => Duration(milliseconds: frames * 1000 ~/ fps);
}

/// The outcome of one build: exactly one of [letter] and [refusal] is set.
class VideoBuildResult {
  const VideoBuildResult.letter(VideoLetter this.letter) : refusal = null;
  const VideoBuildResult.refused(VideoLetterRefusal this.refusal)
    : letter = null;
  final VideoLetter? letter;
  final VideoLetterRefusal? refusal;
}

/// What a caller needs from one take, so the phone peer can be driven in a
/// unit test with no camera. [CameraVideoSelection] is the only
/// implementation that opens a real camera.
abstract class VideoSelection {
  /// Opens the camera and returns the recorded clip's path, or null when
  /// the person backed out. Throws [VideoLetterUnavailable] when the
  /// camera itself cannot run.
  Future<String?> capture();

  /// Reads the clip and encodes it under [budget] bytes.
  Future<VideoBuildResult> build(String path, {required int budget});

  /// The last error text, for [VideoLetterRefusal.failed].
  String? get error;
}

/// The production selection: the system camera through `image_picker`,
/// the Runner's reader, the FFI encoder on a worker isolate.
class CameraVideoSelection implements VideoSelection {
  CameraVideoSelection({ImagePicker? picker})
    : _picker = picker ?? ImagePicker();

  final ImagePicker _picker;

  @override
  String? error;

  @override
  Future<String?> capture() async {
    final XFile? clip;
    try {
      clip = await _picker.pickVideo(
        source: ImageSource.camera,
        maxDuration: videoLetterMaxLength,
        preferredCameraDevice: CameraDevice.front,
      );
    } on Object catch (e) {
      throw VideoLetterUnavailable('$e');
    }
    return clip?.path;
  }

  @override
  Future<VideoBuildResult> build(String path, {required int budget}) async {
    final Map<Object?, Object?>? read;
    try {
      read = await photoLetterFallbackChannel.invokeMapMethod<Object?, Object?>(
        'readVideoLetterSource',
        {
          'path': path,
          'width': videoLetterWidth,
          'height': videoLetterHeight,
          'fps': videoLetterFps,
          'seconds': videoLetterMaxLength.inMilliseconds / 1000,
          // 16 kHz for the wideband Opus tail: an 8 kHz mix would make
          // WB packets that carry nothing above 4 kHz (Fable's trap).
          'audioRate': 16000,
        },
      );
    } on PlatformException catch (e) {
      error = '${e.code}: ${e.message}';
      return const VideoBuildResult.refused(VideoLetterRefusal.unreadable);
    }
    final framesPath = read?['frames'] as String?;
    final audioPath = read?['audio'] as String?;
    final count = read?['count'] as int? ?? 0;
    if (framesPath == null || audioPath == null || count == 0) {
      error = 'the reader returned no frames';
      return const VideoBuildResult.refused(VideoLetterRefusal.unreadable);
    }
    final i420 = await File(framesPath).readAsBytes();
    final pcm = await File(audioPath).readAsBytes();
    final started = DateTime.now();
    try {
      final build = await encodeVideoLetter(
        i420: i420,
        pcm16k: pcm,
        width: videoLetterWidth,
        height: videoLetterHeight,
        fps: videoLetterFps,
        budget: budget,
      );
      return VideoBuildResult.letter(
        VideoLetter(
          wire: build.wire,
          frames: build.frames,
          fps: videoLetterFps,
          crf: build.crf,
          audioPackets: build.audioPackets,
          passes: build.passes,
          encodeMs: DateTime.now().difference(started).inMilliseconds,
        ),
      );
    } on VideoLetterTooLong catch (e) {
      error = '$e';
      return const VideoBuildResult.refused(VideoLetterRefusal.tooLong);
    } on Object catch (e) {
      error = '$e';
      return const VideoBuildResult.refused(VideoLetterRefusal.failed);
    } finally {
      for (final p in [framesPath, audioPath, path]) {
        try {
          File(p).deleteSync();
        } on Object {
          // A temp file that stays is not a failed letter.
        }
      }
    }
  }
}

/// The budget a video letter may spend: thirty letters (letter_parts.dart).
int videoLetterBudgetBytes() => letterMaxTotalBytes();
