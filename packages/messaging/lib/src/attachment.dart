/// Kind of binary attachment shared in chat.
enum MediaKind { image, video, file }

/// A complete binary attachment (photo / video / file). Large attachments are
/// split into chunks for transport and reassembled on the far side; see
/// `attachment_transfer.dart`.
class Attachment {
  final String id;
  final MediaKind kind;

  /// MIME type, e.g. 'image/jpeg', 'video/mp4', 'application/pdf'.
  final String contentType;

  final List<int> bytes;

  Attachment({
    required this.id,
    required this.kind,
    required this.contentType,
    required List<int> bytes,
  }) : bytes = List.unmodifiable(bytes) {
    if (id.isEmpty) throw ArgumentError('id must not be empty');
  }

  int get sizeBytes => bytes.length;
}
