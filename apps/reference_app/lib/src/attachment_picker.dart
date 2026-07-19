/// Standard-platform file picking for the Chat tab: wraps
/// `file_selector`'s [openFile] dialog into the plain
/// `Future<Attachment?> Function()` seam [ChatDemoController] accepts —
/// tests inject a fake picker through the same seam, so no real dialog is
/// ever needed in a widget test.
library;

import 'package:file_selector/file_selector.dart';
import 'package:messaging/messaging.dart';

/// Opens the platform file dialog and returns the chosen file as an
/// [Attachment], or null if the user cancels.
Future<Attachment?> pickAttachmentFile() async {
  final file = await openFile();
  if (file == null) return null;
  final bytes = await file.readAsBytes();
  final mime = file.mimeType ?? 'application/octet-stream';
  return Attachment(
    id: 'picked-${DateTime.now().microsecondsSinceEpoch}',
    kind: mime.startsWith('image/') ? MediaKind.image : MediaKind.file,
    contentType: mime,
    bytes: bytes,
  );
}
