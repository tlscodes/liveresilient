/// Picks one photo from this device's library and shrinks it until it fits
/// the DNS-valve lane's 4096-byte payload cap — the third way to author a
/// letter on the phone, beside a typed draft and a Codec2 voice recording
/// (voice_letter_recorder.dart), on the same `chat_source: phone` path in
/// journey_peer_app.dart.
///
/// The lane capacity question was already answered from the Mac side: an
/// arbitrary 3586-byte JPEG rode this exact lane byte-perfect (session
/// V25YV7). What did not exist was the phone actually choosing one, so this
/// file is only about getting a real photo down to that size and saying, in
/// plain words on the screen, when it cannot.
///
/// Kept out of journey_peer_app.dart for the same reason the recorder is:
/// [shrinkPhotoLetter] is a pure function of bytes, so the whole
/// size-to-cap ladder is unit-testable with no picker, no camera roll and no
/// device.
library;

import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';

/// The hard ceiling on an encoded photo letter, in bytes.
///
/// The lane's own cap is 4096 (`TxtQueryLane.maxPayloadBytes`, enforced again
/// by `DnsValveConfig.parse`). This is deliberately 512 bytes under it: the
/// point of the headroom is that a letter is never refused at the wire for a
/// handful of bytes the encoder happened to spend, and the proven Mac-side
/// baseline (3586 B) already sits below this line.
const int photoLetterMaxBytes = 3584;

/// The long-edge ladder, largest first. The search takes the LARGEST size
/// that can be made to fit at an acceptable quality, because a photo letter
/// is looked at, and a 64-pixel thumbnail of a screenshot is unreadable at
/// any quality.
const List<int> photoLetterEdges = <int>[
  640,
  512,
  416,
  352,
  288,
  240,
  200,
  168,
  140,
  112,
  88,
  64,
  48,
];

/// The JPEG quality ladder tried at each edge, best first. The floor is 20
/// and not lower on purpose: below it the result is blocks, not a picture,
/// and a smaller-but-honest size is the better answer.
const List<int> photoLetterQualities = <int>[75, 65, 55, 45, 38, 32, 26, 20];

/// Thrown when the picker itself cannot run — photo-library permission
/// refused, or the plugin failed. The caller falls back to the typed-letter
/// path exactly as it does for a microphone that will not open.
class PhotoLetterUnavailable implements Exception {
  final String reason;
  PhotoLetterUnavailable(this.reason);
  @override
  String toString() => 'PhotoLetterUnavailable($reason)';
}

/// Why a pick produced no letter. A refusal is never a crash — the caller
/// falls back to text — but the person holding the phone is told which one
/// it was, in those words, right at the button.
enum PhotoLetterRefusal {
  /// The picker opened and the person backed out without choosing.
  cancelled,

  /// The chosen file is not an image this build can decode.
  unreadable,

  /// Decoded fine, but no rung of the ladder got it under
  /// [photoLetterMaxBytes]. Refused rather than carried truncated.
  tooLarge,

  /// The picker or the encoder threw; the text is in
  /// [PhotoSelection.pickError].
  failed,
}

/// One photo, shrunk and encoded, ready to ride the lane as opaque bytes
/// exactly like a typed letter's UTF-8 or a voice letter's Codec2 frames.
class PhotoLetter {
  const PhotoLetter({
    required this.wire,
    required this.width,
    required this.height,
    required this.quality,
    required this.sourceBytes,
  });

  /// The encoded JPEG — this is the payload.
  final Uint8List wire;

  /// The encoded pixel width, after the ladder shrank it.
  final int width;

  /// The encoded pixel height, after the ladder shrank it.
  final int height;

  /// The JPEG quality that produced [wire].
  final int quality;

  /// How many bytes the picker handed over before shrinking, so the screen
  /// can say what the ladder actually did.
  final int sourceBytes;
}

/// A human-readable size, for the button and the preview line. Bytes under a
/// kilobyte are named exactly, because at this cap the exact count is the
/// interesting number.
String photoLetterSize(int bytes) =>
    bytes < 1024 ? '$bytes B' : '${(bytes / 1024).toStringAsFixed(1)} KB';

/// The outcome of one shrink: exactly one of [letter] and [refusal] is set.
///
/// A result rather than a nullable letter, because "that file is not a
/// picture" and "that picture will not fit" are different things to tell the
/// person, and a bare null cannot tell them apart.
class PhotoShrinkResult {
  const PhotoShrinkResult.letter(PhotoLetter this.letter) : refusal = null;
  const PhotoShrinkResult.refused(PhotoLetterRefusal this.refusal)
    : letter = null;

  final PhotoLetter? letter;
  final PhotoLetterRefusal? refusal;
}

/// Shrinks [source] until the encoded JPEG fits [maxBytes], or refuses.
///
/// The search takes the largest edge in [photoLetterEdges] that fits at some
/// quality in [photoLetterQualities], and at that edge the best quality that
/// fits. It never targets the cap exactly — a candidate is accepted only
/// when it is at or under [maxBytes], which is itself under the lane's cap.
///
/// Pure, synchronous, and free of Flutter: the caller runs it on a worker
/// isolate for a full-size photo, and a unit test calls it directly.
PhotoShrinkResult shrinkPhotoLetter(
  Uint8List source, {
  int maxBytes = photoLetterMaxBytes,
}) {
  final decoded = img.decodeImage(source);
  if (decoded == null) {
    return const PhotoShrinkResult.refused(PhotoLetterRefusal.unreadable);
  }
  // Phone cameras and screenshots carry their rotation in EXIF; without this
  // a portrait picture arrives on its side and nobody can tell whether the
  // lane or the encoder did it.
  final upright = img.bakeOrientation(decoded);
  final wide = upright.width >= upright.height;
  final longEdge = wide ? upright.width : upright.height;
  for (final edge in photoLetterEdges) {
    // Never upscale, and never encode the same pixels twice: a source
    // already smaller than this rung is handled once, at the first rung, and
    // every larger rung below it is skipped.
    if (edge > longEdge && edge != photoLetterEdges.first) continue;
    final scaled = edge >= longEdge
        ? upright
        : img.copyResize(
            upright,
            width: wide ? edge : null,
            height: wide ? null : edge,
            interpolation: img.Interpolation.average,
          );
    for (final quality in photoLetterQualities) {
      // yuv420 chroma subsampling, not the library default yuv444: at this
      // budget the chroma planes are worth a quarter of the bytes for a
      // difference nobody sees on a 200-pixel letter.
      final encoded = img.encodeJpg(
        scaled,
        quality: quality,
        chroma: img.JpegChroma.yuv420,
      );
      if (encoded.length <= maxBytes) {
        return PhotoShrinkResult.letter(
          PhotoLetter(
            wire: encoded,
            width: scaled.width,
            height: scaled.height,
            quality: quality,
            sourceBytes: source.length,
          ),
        );
      }
    }
  }
  return const PhotoShrinkResult.refused(PhotoLetterRefusal.tooLarge);
}

/// What a caller needs from one pick, so the phone peer can be driven in a
/// unit test with no photo library. [GalleryPhotoSelection] is the only
/// implementation that opens a real picker.
abstract class PhotoSelection {
  /// Opens the picker and returns the raw bytes the person chose, or null
  /// when they backed out. Throws [PhotoLetterUnavailable] when the picker
  /// itself cannot run.
  Future<Uint8List?> pick();

  /// Shrinks picked bytes to a letter, or says why it could not. Async
  /// because the real one hands the work to a worker isolate — a full-size
  /// photo decodes for seconds, and doing that on the UI isolate would
  /// freeze the very button that is showing "Shrinking…".
  Future<PhotoShrinkResult> shrink(Uint8List source);

  /// The error text behind [PhotoLetterRefusal.failed].
  String? get pickError;
}

/// The real pick: the system photo library, shrunk on a worker isolate.
///
/// The library and not the camera, deliberately. A rig run has to be
/// repeatable — the same picture, chosen twice, produces the same bytes —
/// and a phone screenshot, which is the thing most worth sending over this
/// lane, only ever exists in the library. The camera would also put a
/// viewfinder between the person and a 120-second Send window.
class GalleryPhotoSelection implements PhotoSelection {
  GalleryPhotoSelection({
    ImagePicker? picker,
    this.shrinker = shrinkPhotoLetter,
  }) : _picker = picker ?? ImagePicker();

  final ImagePicker _picker;

  /// The shrink step, so a test can supply a fast fake. Production is
  /// [shrinkPhotoLetter], and only that one is sent to a worker isolate.
  final PhotoShrinkResult Function(Uint8List) shrinker;

  String? _pickError;

  @override
  String? get pickError => _pickError;

  @override
  Future<Uint8List?> pick() async {
    final XFile? file;
    try {
      // The native resize is the cheap one: a 12-megapixel screenshot comes
      // back at 1600 px without ever being decoded in Dart, which is most of
      // the seconds the shrink would otherwise cost.
      file = await _picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1600,
        maxHeight: 1600,
        imageQuality: 85,
      );
    } on Object catch (error) {
      _pickError = '$error';
      throw PhotoLetterUnavailable('$error');
    }
    if (file == null) return null;
    try {
      return await file.readAsBytes();
    } on Object catch (error) {
      _pickError = '$error';
      throw PhotoLetterUnavailable('$error');
    }
  }

  @override
  Future<PhotoShrinkResult> shrink(Uint8List source) async {
    final ladder = shrinker;
    try {
      // A stub supplied by a test runs in place — spawning an isolate to
      // call a fake is slower and harder to reason about. The real ladder
      // goes to a worker isolate, which is the whole reason this method is
      // async.
      if (!identical(ladder, shrinkPhotoLetter)) return ladder(source);
      return await Isolate.run(() => shrinkPhotoLetter(source));
    } on Object catch (error) {
      _pickError = '$error';
      return const PhotoShrinkResult.refused(PhotoLetterRefusal.failed);
    }
  }
}
