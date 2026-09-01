/// FFI binding to Brotli for the NewsPage wire (FULL_TEST_PLAN T3, NewsPage
/// row: full page decode on the device).
///
/// compact_news_codec takes injectable BrotliCompress/BrotliDecompress
/// functions; these are the production implementations. Encode is bound at
/// quality 11 to match the phase-5 host measurement; decode is a one-shot
/// BrotliDecoderDecompress with an explicit plaintext cap.
///
/// Library resolution mirrors zstd_ffi: BROTLI_LIB_DIR env var (a directory
/// holding libbrotlidec/libbrotlienc dylibs), the app-bundled frameworks on
/// iOS, then the host brew paths.
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

DynamicLibrary _openPart(String stem, String iosFramework) {
  final dir = Platform.environment['BROTLI_LIB_DIR'];
  if (dir != null && dir.isNotEmpty) {
    return DynamicLibrary.open('$dir/lib$stem.dylib');
  }
  if (Platform.isIOS) {
    return DynamicLibrary.open('$iosFramework.framework/$iosFramework');
  }
  for (final p in [
    '/usr/local/opt/brotli/lib/lib$stem.dylib',
    '/opt/homebrew/opt/brotli/lib/lib$stem.dylib',
    // Linux: distribution packages install the versioned soname; the bare
    // .so exists only when the -dev package is present.
    '/usr/lib/x86_64-linux-gnu/lib$stem.so.1',
    '/usr/lib/x86_64-linux-gnu/lib$stem.so',
    '/usr/lib/aarch64-linux-gnu/lib$stem.so.1',
    '/usr/lib/aarch64-linux-gnu/lib$stem.so',
  ]) {
    if (File(p).existsSync()) return DynamicLibrary.open(p);
  }
  return DynamicLibrary.process();
}

final DynamicLibrary _dec = _openPart('brotlidec', 'brotlidec');
// uplift 2026-08-20: the device vendors DECODE only (brotlidec/common);
// calling brotliEncode there used to die in a cryptic dlopen error. It
// now names the actual situation.
final DynamicLibrary _enc = (() {
  try {
    return _openPart('brotlienc', 'brotlienc');
  } on ArgumentError catch (e) {
    throw StateError(
      'brotli ENCODER library not available on this platform (the app '
      'bundles decode-only frameworks; encode is a host/server path): $e',
    );
  }
})();

typedef _DecompressC =
    Int32 Function(UintPtr, Pointer<Uint8>, Pointer<UintPtr>, Pointer<Uint8>);
typedef _DecompressD =
    int Function(int, Pointer<Uint8>, Pointer<UintPtr>, Pointer<Uint8>);
typedef _CompressC =
    Int32 Function(
      Int32,
      Int32,
      Int32,
      UintPtr,
      Pointer<Uint8>,
      Pointer<UintPtr>,
      Pointer<Uint8>,
    );
typedef _CompressD =
    int Function(
      int,
      int,
      int,
      int,
      Pointer<Uint8>,
      Pointer<UintPtr>,
      Pointer<Uint8>,
    );

final _decompress = _dec.lookupFunction<_DecompressC, _DecompressD>(
  'BrotliDecoderDecompress',
);
final _compress = _enc.lookupFunction<_CompressC, _CompressD>(
  'BrotliEncoderCompress',
);

/// BROTLI_DECODER_RESULT_SUCCESS / BROTLI_TRUE from the C headers.
const _decoderSuccess = 1;
const _encoderTrue = 1;

/// One-shot decode; [maxOut] caps the plaintext (news pages are bounded by
/// the 1536B wire budget's expansion — a page claiming more is malformed).
Uint8List brotliDecode(Uint8List wire, {int maxOut = 1 << 22}) {
  final srcP = malloc<Uint8>(wire.length);
  srcP.asTypedList(wire.length).setAll(0, wire);
  final dstP = malloc<Uint8>(maxOut);
  final outLen = malloc<UintPtr>()..value = maxOut;
  try {
    final rc = _decompress(wire.length, srcP, outLen, dstP);
    if (rc != _decoderSuccess) {
      throw StateError('BrotliDecoderDecompress failed (rc=$rc)');
    }
    return Uint8List.fromList(dstP.asTypedList(outLen.value));
  } finally {
    malloc.free(srcP);
    malloc.free(dstP);
    malloc.free(outLen);
  }
}

/// Quality-11 encode, the phase-5 measurement setting (lgwin 22 default).
Uint8List brotliEncode(Uint8List raw, {int quality = 11, int lgwin = 22}) {
  final srcP = malloc<Uint8>(raw.length);
  srcP.asTypedList(raw.length).setAll(0, raw);
  final cap = raw.length + (raw.length >> 1) + 1024;
  final dstP = malloc<Uint8>(cap);
  final outLen = malloc<UintPtr>()..value = cap;
  try {
    final rc = _compress(quality, lgwin, 0, raw.length, srcP, outLen, dstP);
    if (rc != _encoderTrue) {
      throw StateError('BrotliEncoderCompress failed');
    }
    return Uint8List.fromList(dstP.asTypedList(outLen.value));
  } finally {
    malloc.free(srcP);
    malloc.free(dstP);
    malloc.free(outLen);
  }
}
