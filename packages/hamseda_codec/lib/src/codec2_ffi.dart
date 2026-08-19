/// FFI binding to libcodec2 with NativeFinalizer-owned instance lifetime
/// (FULL_TEST_PLAN T2.2).
///
/// Library resolution order:
///   1. CODEC2_LIB_PATH environment variable (host tests point this at the
///      repo's 450-capable build — measured-on-host)
///   2. the repo-relative host dylib, when running from a package checkout
///   3. DynamicLibrary.process() — the device app links the static
///      libcodec2.xcframework, so the symbols live in-process there.
///
/// Memory contract: every [Codec2] is registered with a [NativeFinalizer]
/// that calls codec2_destroy when the Dart object is collected, so a leaked
/// instance can never leak native state. [dispose] destroys eagerly and
/// detaches the finalizer; double-destroy is therefore impossible by
/// construction (dispose nulls the pointer and detaches).
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

/// Codec2 mode ids from codec2.h (the 450-capable revision the repo pins).
const int codec2Mode700C = 8;
const int codec2Mode450 = 10;

typedef _CreateC = Pointer<Void> Function(Int32);
typedef _CreateD = Pointer<Void> Function(int);
typedef _VoidPtrC = Void Function(Pointer<Void>);
typedef _EncodeC = Void Function(Pointer<Void>, Pointer<Uint8>, Pointer<Int16>);
typedef _EncodeD = void Function(Pointer<Void>, Pointer<Uint8>, Pointer<Int16>);
typedef _DecodeC = Void Function(Pointer<Void>, Pointer<Int16>, Pointer<Uint8>);
typedef _DecodeD = void Function(Pointer<Void>, Pointer<Int16>, Pointer<Uint8>);
typedef _IntOfPtrC = Int32 Function(Pointer<Void>);
typedef _IntOfPtrD = int Function(Pointer<Void>);

DynamicLibrary _openLibCodec2() {
  final env = Platform.environment['CODEC2_LIB_PATH'];
  if (env != null && env.isNotEmpty) return DynamicLibrary.open(env);
  if (Platform.isIOS) return DynamicLibrary.open('codec2.framework/codec2');
  // package checkout layout: packages/hamseda_codec -> repo root
  final repoLocal = File(
    '${Directory.current.path}/../../tools/phase5/native/codec2_450/build/src/libcodec2.dylib',
  );
  if (repoLocal.existsSync()) return DynamicLibrary.open(repoLocal.path);
  return DynamicLibrary.process();
}

final DynamicLibrary _lib = _openLibCodec2();

final _create = _lib.lookupFunction<_CreateC, _CreateD>('codec2_create');
final _encode = _lib.lookupFunction<_EncodeC, _EncodeD>('codec2_encode');
final _decode = _lib.lookupFunction<_DecodeC, _DecodeD>('codec2_decode');
final _samplesPerFrame =
    _lib.lookupFunction<_IntOfPtrC, _IntOfPtrD>('codec2_samples_per_frame');
final _bitsPerFrame =
    _lib.lookupFunction<_IntOfPtrC, _IntOfPtrD>('codec2_bits_per_frame');
final _destroyPtr =
    _lib.lookup<NativeFunction<_VoidPtrC>>('codec2_destroy');
final _finalizer = NativeFinalizer(_destroyPtr.cast());
// uplift 2026-08-20: the state finalizer only ran codec2_destroy — the
// per-instance malloc'd scratch buffers LEAKED for every abandoned
// instance (the no-crash churn test abandons ~2000 of them ≈ 1.3MB/run,
// silent). Each buffer now carries its own native-free finalizer.
final _bufFinalizer = NativeFinalizer(malloc.nativeFree);

class Codec2 implements Finalizable {
  Codec2(int mode) : _state = _create(mode) {
    if (_state == nullptr) {
      throw StateError('codec2_create($mode) returned null');
    }
    _finalizer.attach(this, _state.cast(), detach: this);
    samplesPerFrame = _samplesPerFrame(_state);
    bitsPerFrame = _bitsPerFrame(_state);
    _bytesPerFrame = (bitsPerFrame + 7) >> 3;
    _speech = malloc<Int16>(samplesPerFrame);
    _bits = malloc<Uint8>(_bytesPerFrame);
    _bufFinalizer.attach(this, _speech.cast(), detach: _speechToken);
    _bufFinalizer.attach(this, _bits.cast(), detach: _bitsToken);
  }

  // detach keys (NativeFinalizer forbids Pointer/primitive detach tokens)
  final Object _speechToken = Object();
  final Object _bitsToken = Object();

  Pointer<Void> _state;
  late final int samplesPerFrame;
  late final int bitsPerFrame;
  late final int _bytesPerFrame;
  late final Pointer<Int16> _speech;
  late final Pointer<Uint8> _bits;

  void _checkLive() {
    if (_state == nullptr) throw StateError('Codec2 used after dispose');
  }

  /// Encodes one frame ([samplesPerFrame] s16 samples) into packed bits.
  Uint8List encodeFrame(Int16List speech) {
    _checkLive();
    if (speech.length != samplesPerFrame) {
      throw ArgumentError('need $samplesPerFrame samples, got ${speech.length}');
    }
    _speech.asTypedList(samplesPerFrame).setAll(0, speech);
    _encode(_state, _bits, _speech);
    return Uint8List.fromList(_bits.asTypedList(_bytesPerFrame));
  }

  /// Decodes one packed frame back into [samplesPerFrame] s16 samples.
  Int16List decodeFrame(Uint8List bits) {
    _checkLive();
    if (bits.length != _bytesPerFrame) {
      throw ArgumentError('need $_bytesPerFrame bytes, got ${bits.length}');
    }
    _bits.asTypedList(_bytesPerFrame).setAll(0, bits);
    _decode(_state, _speech, _bits);
    return Int16List.fromList(_speech.asTypedList(samplesPerFrame));
  }

  /// Eager teardown; the finalizer is detached so GC can never double-free.
  void dispose() {
    if (_state == nullptr) return;
    _finalizer.detach(this);
    _bufFinalizer.detach(_speechToken);
    _bufFinalizer.detach(_bitsToken);
    final s = _state;
    _state = nullptr;
    malloc.free(_speech);
    malloc.free(_bits);
    // direct call through the same symbol the finalizer uses
    _destroyPtr.asFunction<void Function(Pointer<Void>)>()(s);
  }
}
