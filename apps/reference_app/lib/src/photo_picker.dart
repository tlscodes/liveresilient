import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import 'photo_source.dart';

/// Picks raw photo bytes from the OS photo library or camera (image_picker
/// on mobile). Desktop dev builds have no camera/photo-roll surface, so the
/// same call degrades to the OS file dialog — the flow stays demonstrable
/// everywhere. Returns null when the user cancels.
Future<Uint8List?> pickPhotoBytes(PhotoSource source) async {
  try {
    final picked = await ImagePicker().pickImage(
      source: source == PhotoSource.camera
          ? ImageSource.camera
          : ImageSource.gallery,
      // A soft OS-side cap; the ingest pass enforces the wire contract
      // (2048 px q80) regardless of what the platform hands back.
      maxWidth: 4096,
      maxHeight: 4096,
    );
    if (picked == null) return null;
    return await picked.readAsBytes();
  } on PlatformException {
    return _fallbackFileDialog();
  } on MissingPluginException {
    return _fallbackFileDialog();
  } on UnimplementedError {
    return _fallbackFileDialog();
  }
}

Future<Uint8List?> _fallbackFileDialog() async {
  const group = XTypeGroup(
    label: 'images',
    extensions: ['jpg', 'jpeg', 'png', 'heic', 'webp'],
  );
  final file = await openFile(acceptedTypeGroups: const [group]);
  if (file == null) return null;
  return file.readAsBytes();
}
