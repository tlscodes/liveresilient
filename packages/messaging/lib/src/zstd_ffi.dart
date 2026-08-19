/// FFI binding to libzstd for the compact-text wire (FULL_TEST_PLAN T3,
/// Text row: full decode on the device).
///
/// The codec (compact_text_codec.dart) takes injectable
/// `Compressor`/`Decompressor` functions; this is the production
/// implementation. Generation 2 (uplift 2026-08-20): the dictionary is
/// DIGESTED once into ZSTD_CDict/ZSTD_DDict — zstd's intended API for a
/// dictionary used across many messages — and one CCtx/DCtx pair persists
/// per instance instead of being created and torn down on every call.
/// Level stays pinned to the phase-5 measurement (zstd -19, trained chat
/// dictionary). Use-after-dispose fails loud before any native call.
///
/// Library resolution: ZSTD_LIB_PATH env var, then the app-bundled
/// zstd.framework (iOS), then the host's brew dylib, then process symbols.
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

DynamicLibrary _open() {
  final env = Platform.environment['ZSTD_LIB_PATH'];
  if (env != null && env.isNotEmpty) return DynamicLibrary.open(env);
  if (Platform.isIOS) return DynamicLibrary.open('zstd.framework/zstd');
  for (final p in [
    '/usr/local/opt/zstd/lib/libzstd.dylib',
    '/opt/homebrew/opt/zstd/lib/libzstd.dylib',
  ]) {
    if (File(p).existsSync()) return DynamicLibrary.open(p);
  }
  return DynamicLibrary.process();
}

final DynamicLibrary _lib = _open();

typedef _CBound = UintPtr Function(UintPtr);
typedef _CBoundD = int Function(int);
typedef _IsErrC = Uint32 Function(UintPtr);
typedef _IsErrD = int Function(int);
typedef _CreateC = Pointer<Void> Function();
typedef _CreateD = Pointer<Void> Function();
typedef _FreeC = UintPtr Function(Pointer<Void>);
typedef _FreeD = int Function(Pointer<Void>);
typedef _CreateCDictC = Pointer<Void> Function(Pointer<Void>, UintPtr, Int32);
typedef _CreateCDictD = Pointer<Void> Function(Pointer<Void>, int, int);
typedef _CreateDDictC = Pointer<Void> Function(Pointer<Void>, UintPtr);
typedef _CreateDDictD = Pointer<Void> Function(Pointer<Void>, int);
typedef _CompressCDictC = UintPtr Function(Pointer<Void>, Pointer<Void>,
    UintPtr, Pointer<Void>, UintPtr, Pointer<Void>);
typedef _CompressCDictD = int Function(
    Pointer<Void>, Pointer<Void>, int, Pointer<Void>, int, Pointer<Void>);
typedef _DecompressDDictC = UintPtr Function(Pointer<Void>, Pointer<Void>,
    UintPtr, Pointer<Void>, UintPtr, Pointer<Void>);
typedef _DecompressDDictD = int Function(
    Pointer<Void>, Pointer<Void>, int, Pointer<Void>, int, Pointer<Void>);

final _compressBound =
    _lib.lookupFunction<_CBound, _CBoundD>('ZSTD_compressBound');
final _isError = _lib.lookupFunction<_IsErrC, _IsErrD>('ZSTD_isError');
final _createCCtx = _lib.lookupFunction<_CreateC, _CreateD>('ZSTD_createCCtx');
final _freeCCtx = _lib.lookupFunction<_FreeC, _FreeD>('ZSTD_freeCCtx');
final _createDCtx = _lib.lookupFunction<_CreateC, _CreateD>('ZSTD_createDCtx');
final _freeDCtx = _lib.lookupFunction<_FreeC, _FreeD>('ZSTD_freeDCtx');
final _createCDict =
    _lib.lookupFunction<_CreateCDictC, _CreateCDictD>('ZSTD_createCDict');
final _freeCDict = _lib.lookupFunction<_FreeC, _FreeD>('ZSTD_freeCDict');
final _createDDict =
    _lib.lookupFunction<_CreateDDictC, _CreateDDictD>('ZSTD_createDDict');
final _freeDDict = _lib.lookupFunction<_FreeC, _FreeD>('ZSTD_freeDDict');
final _compressUsingCDict = _lib
    .lookupFunction<_CompressCDictC, _CompressCDictD>(
        'ZSTD_compress_usingCDict');
final _decompressUsingDDict =
    _lib.lookupFunction<_DecompressDDictC, _DecompressDDictD>(
        'ZSTD_decompress_usingDDict');

/// Dictionary-aware zstd codec, level pinned to the phase-5 measurement
/// (zstd -19 trained on chat_train_2000). The raw dictionary bytes are
/// digested at construction and freed immediately after — the digested
/// CDict/DDict live for the instance's lifetime.
class ZstdChat {
  ZstdChat(Uint8List dictionary, {this.level = 19}) {
    final dictP = malloc<Uint8>(dictionary.length);
    dictP.asTypedList(dictionary.length).setAll(0, dictionary);
    _cdict = _createCDict(dictP.cast(), dictionary.length, level);
    _ddict = _createDDict(dictP.cast(), dictionary.length);
    malloc.free(dictP); // CDict/DDict hold their own internal copies
    if (_cdict == nullptr || _ddict == nullptr) {
      throw StateError('zstd dictionary digestion failed');
    }
    _cctx = _createCCtx();
    _dctx = _createDCtx();
  }

  final int level;
  late final Pointer<Void> _cdict;
  late final Pointer<Void> _ddict;
  late final Pointer<Void> _cctx;
  late final Pointer<Void> _dctx;
  bool _disposed = false;

  // use-after-dispose used to hand freed memory to the native side —
  // undefined behavior with no diagnosis. It fails loud instead.
  void _checkLive() {
    if (_disposed) throw StateError('ZstdChat used after dispose');
  }

  /// Compressor closure matching compact_text_codec's injectable typedef.
  Uint8List compress(Uint8List raw) {
    _checkLive();
    final srcP = malloc<Uint8>(raw.length);
    srcP.asTypedList(raw.length).setAll(0, raw);
    final cap = _compressBound(raw.length);
    final dstP = malloc<Uint8>(cap);
    try {
      final n = _compressUsingCDict(
          _cctx, dstP.cast(), cap, srcP.cast(), raw.length, _cdict);
      if (_isError(n) != 0) {
        throw StateError('ZSTD_compress_usingCDict failed (code $n)');
      }
      return Uint8List.fromList(dstP.asTypedList(n));
    } finally {
      malloc.free(srcP);
      malloc.free(dstP);
    }
  }

  /// Decompressor closure; [maxOut] caps the plaintext (wire messages are
  /// chat-sized — a frame claiming more than this is malformed, not data).
  Uint8List decompress(Uint8List body, {int maxOut = 1 << 20}) {
    _checkLive();
    final srcP = malloc<Uint8>(body.length);
    srcP.asTypedList(body.length).setAll(0, body);
    final dstP = malloc<Uint8>(maxOut);
    try {
      final n = _decompressUsingDDict(
          _dctx, dstP.cast(), maxOut, srcP.cast(), body.length, _ddict);
      if (_isError(n) != 0) {
        throw StateError('ZSTD_decompress_usingDDict failed (code $n)');
      }
      return Uint8List.fromList(dstP.asTypedList(n));
    } finally {
      malloc.free(srcP);
      malloc.free(dstP);
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _freeCCtx(_cctx);
    _freeDCtx(_dctx);
    _freeCDict(_cdict);
    _freeDDict(_ddict);
  }
}
