/// FFI binding to libopus 1.5.2 for the voice letter's mode 12: Opus
/// 6 kbit/s narrowband, hard CBR, 60 ms frames — 45 B per frame, 750 B/s,
/// 30 s of speech in six letters. The same 8 kHz s16 PCM the Codec2 path
/// takes goes straight in (Opus accepts 8 kHz input; SILK is forced at
/// 6 kbit/s), so the recorder, the wire, and the receivers need no
/// resampling.
///
/// Library resolution order, mirroring codec2_ffi.dart:
///   1. OPUS_LIB_PATH environment variable
///   2. iOS: the vendored dynamic framework 'opus.framework/opus'
///      (apps/reference_app/ios/NativeCodecs/opus.xcframework, built by
///      tools/phase5/native/make_opus.sh from opus-1.5.2.tar.gz)
///   3. the repo-relative host dylib (tools/phase5/native/opus-mac)
///   4. DynamicLibrary.process()
///
/// Memory contract: encoder and decoder states are owned by a
/// NativeFinalizer (opus_encoder_destroy / opus_decoder_destroy); [dispose]
/// destroys eagerly and detaches, so double-free is impossible by
/// construction. Scratch buffers carry their own free finalizer.
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'voice_frame_codec.dart';

// opus_defines.h
const int _opusOk = 0;
const int _opusApplicationVoip = 2048;
const int _opusSetBitrate = 4002;
const int _opusSetMaxBandwidth = 4004;
const int _opusSetVbr = 4006;
const int _opusSetBandwidth = 4008;
const int _opusSetComplexity = 4010;
const int _opusSetInbandFec = 4012;
const int _opusSetPacketLossPerc = 4014;
const int _opusSetDtx = 4016;
const int _opusSetVbrConstraint = 4020;
const int _opusSetSignal = 4024;
const int _opusSetLsbDepth = 4036;
const int _opusBandwidthNarrowband = 1101;
const int _opusSignalVoice = 3001;

/// The wire's fixed frame: 6000 bit/s × 60 ms / 8 = 45 B, exactly, in hard
/// CBR (libopus pads every packet to the bitrate's byte count).
const int opusVoiceSampleRate = 8000;
const int opusVoiceFrameMs = 60;
const int opusVoiceSamplesPerFrame =
    opusVoiceSampleRate * opusVoiceFrameMs ~/ 1000;
const int opusVoiceBitrate = 6000;
const int opusVoiceFrameBytes = opusVoiceBitrate * opusVoiceFrameMs ~/ 8000;

typedef _EncCreateC =
    Pointer<Void> Function(Int32, Int32, Int32, Pointer<Int32>);
typedef _EncCreateD = Pointer<Void> Function(int, int, int, Pointer<Int32>);
typedef _DecCreateC = Pointer<Void> Function(Int32, Int32, Pointer<Int32>);
typedef _DecCreateD = Pointer<Void> Function(int, int, Pointer<Int32>);
typedef _CtlIntC = Int32 Function(Pointer<Void>, Int32, VarArgs<(Int32,)>);
typedef _CtlIntD = int Function(Pointer<Void>, int, int);
typedef _EncodeC =
    Int32 Function(Pointer<Void>, Pointer<Int16>, Int32, Pointer<Uint8>, Int32);
typedef _EncodeD =
    int Function(Pointer<Void>, Pointer<Int16>, int, Pointer<Uint8>, int);
typedef _DecodeC =
    Int32 Function(
      Pointer<Void>,
      Pointer<Uint8>,
      Int32,
      Pointer<Int16>,
      Int32,
      Int32,
    );
typedef _DecodeD =
    int Function(Pointer<Void>, Pointer<Uint8>, int, Pointer<Int16>, int, int);
typedef _VoidPtrC = Void Function(Pointer<Void>);
typedef _VersionC = Pointer<Utf8> Function();
typedef _VersionD = Pointer<Utf8> Function();

DynamicLibrary _openLibOpus() {
  final env = Platform.environment['OPUS_LIB_PATH'];
  if (env != null && env.isNotEmpty) return DynamicLibrary.open(env);
  if (Platform.isIOS) return DynamicLibrary.open('opus.framework/opus');
  for (final rel in const [
    '../../tools/phase5/native/opus-mac/libopus.dylib',
    'tools/phase5/native/opus-mac/libopus.dylib',
  ]) {
    final f = File('${Directory.current.path}/$rel');
    if (f.existsSync()) return DynamicLibrary.open(f.path);
  }
  return DynamicLibrary.process();
}

final DynamicLibrary _lib = _openLibOpus();
final _encCreate = _lib.lookupFunction<_EncCreateC, _EncCreateD>(
  'opus_encoder_create',
);
final _decCreate = _lib.lookupFunction<_DecCreateC, _DecCreateD>(
  'opus_decoder_create',
);
final _encCtl = _lib.lookupFunction<_CtlIntC, _CtlIntD>('opus_encoder_ctl');
final _decCtl = _lib.lookupFunction<_CtlIntC, _CtlIntD>('opus_decoder_ctl');
final _encode = _lib.lookupFunction<_EncodeC, _EncodeD>('opus_encode');
final _decode = _lib.lookupFunction<_DecodeC, _DecodeD>('opus_decode');
final _encDestroyPtr = _lib.lookup<NativeFunction<_VoidPtrC>>(
  'opus_encoder_destroy',
);
final _decDestroyPtr = _lib.lookup<NativeFunction<_VoidPtrC>>(
  'opus_decoder_destroy',
);
final _version = _lib.lookupFunction<_VersionC, _VersionD>(
  'opus_get_version_string',
);
final _encFinalizer = NativeFinalizer(_encDestroyPtr.cast());
final _decFinalizer = NativeFinalizer(_decDestroyPtr.cast());
final _bufFinalizer = NativeFinalizer(malloc.nativeFree);

/// libopus's own version string, e.g. "libopus 1.5.2".
String opusVersion() => _version().toDartString();

void _check(int rc, String what) {
  if (rc != _opusOk) throw StateError('$what failed: opus error $rc');
}

/// Opus 6 kbit/s NB hard-CBR encoder + decoder over 60 ms frames of 8 kHz
/// s16 PCM; one instance serves either direction. [decoderComplexity] is
/// passed to opus_decoder_ctl and is inert here: the OSCE enhancement
/// (LACE/NoLACE) only runs on 16 kHz SILK with 20 ms frames
/// (dnn/osce.c:933), never on this narrowband 60 ms mode — measured
/// 2026-09-21, complexity 7 decoded byte-identical to 0 — so the vendored
/// library is built without it (make_opus.sh).
class OpusVoice implements VoiceFrameCodec, Finalizable {
  OpusVoice({int decoderComplexity = 0}) {
    final err = malloc<Int32>();
    try {
      _enc = _encCreate(opusVoiceSampleRate, 1, _opusApplicationVoip, err);
      if (_enc == nullptr || err.value != _opusOk) {
        throw StateError('opus_encoder_create failed: ${err.value}');
      }
      _encFinalizer.attach(this, _enc.cast(), detach: _encToken);
      _dec = _decCreate(opusVoiceSampleRate, 1, err);
      if (_dec == nullptr || err.value != _opusOk) {
        throw StateError('opus_decoder_create failed: ${err.value}');
      }
      _decFinalizer.attach(this, _dec.cast(), detach: _decToken);
    } finally {
      malloc.free(err);
    }
    _check(_encCtl(_enc, _opusSetBitrate, opusVoiceBitrate), 'set bitrate');
    _check(_encCtl(_enc, _opusSetVbr, 0), 'set cbr');
    _check(_encCtl(_enc, _opusSetVbrConstraint, 0), 'set vbr constraint');
    _check(_encCtl(_enc, _opusSetSignal, _opusSignalVoice), 'set signal');
    _check(
      _encCtl(_enc, _opusSetMaxBandwidth, _opusBandwidthNarrowband),
      'set max bw',
    );
    _check(
      _encCtl(_enc, _opusSetBandwidth, _opusBandwidthNarrowband),
      'set bw',
    );
    _check(_encCtl(_enc, _opusSetComplexity, 10), 'set complexity');
    _check(_encCtl(_enc, _opusSetInbandFec, 0), 'set fec');
    _check(_encCtl(_enc, _opusSetPacketLossPerc, 0), 'set loss');
    _check(_encCtl(_enc, _opusSetDtx, 0), 'set dtx');
    _check(_encCtl(_enc, _opusSetLsbDepth, 16), 'set lsb depth');
    if (decoderComplexity > 0) {
      _check(
        _decCtl(_dec, _opusSetComplexity, decoderComplexity),
        'set decoder complexity',
      );
    }
    _pcm = malloc<Int16>(opusVoiceSamplesPerFrame);
    _bytes = malloc<Uint8>(opusVoiceFrameBytes * 2);
    _bufFinalizer.attach(this, _pcm.cast(), detach: _pcmToken);
    _bufFinalizer.attach(this, _bytes.cast(), detach: _bytesToken);
  }

  final Object _encToken = Object();
  final Object _decToken = Object();
  final Object _pcmToken = Object();
  final Object _bytesToken = Object();

  Pointer<Void> _enc = nullptr;
  Pointer<Void> _dec = nullptr;
  late final Pointer<Int16> _pcm;
  late final Pointer<Uint8> _bytes;

  @override
  int get samplesPerFrame => opusVoiceSamplesPerFrame;

  @override
  int get bitsPerFrame => opusVoiceFrameBytes * 8;

  void _checkLive() {
    if (_enc == nullptr) throw StateError('OpusVoice used after dispose');
  }

  /// Encodes one 60 ms frame (480 s16 samples at 8 kHz) into exactly
  /// [opusVoiceFrameBytes] bytes.
  @override
  Uint8List encodeFrame(Int16List speech) {
    _checkLive();
    if (speech.length != opusVoiceSamplesPerFrame) {
      throw ArgumentError(
        'need $opusVoiceSamplesPerFrame samples, got ${speech.length}',
      );
    }
    _pcm.asTypedList(opusVoiceSamplesPerFrame).setAll(0, speech);
    final n = _encode(
      _enc,
      _pcm,
      opusVoiceSamplesPerFrame,
      _bytes,
      opusVoiceFrameBytes * 2,
    );
    if (n < 0) throw StateError('opus_encode failed: $n');
    if (n != opusVoiceFrameBytes) {
      throw StateError(
        'opus_encode returned $n B, the wire wants $opusVoiceFrameBytes',
      );
    }
    return Uint8List.fromList(_bytes.asTypedList(n));
  }

  /// Decodes one [opusVoiceFrameBytes]-byte packet into 480 s16 samples.
  @override
  Int16List decodeFrame(Uint8List packet) {
    _checkLive();
    if (packet.length != opusVoiceFrameBytes) {
      throw ArgumentError(
        'need $opusVoiceFrameBytes bytes, got ${packet.length}',
      );
    }
    _bytes.asTypedList(opusVoiceFrameBytes).setAll(0, packet);
    final n = _decode(
      _dec,
      _bytes,
      opusVoiceFrameBytes,
      _pcm,
      opusVoiceSamplesPerFrame,
      0,
    );
    if (n < 0) throw StateError('opus_decode failed: $n');
    if (n != opusVoiceSamplesPerFrame) {
      throw StateError(
        'opus_decode returned $n samples, want $opusVoiceSamplesPerFrame',
      );
    }
    return Int16List.fromList(_pcm.asTypedList(n));
  }

  @override
  void dispose() {
    if (_enc == nullptr) return;
    _encFinalizer.detach(_encToken);
    _decFinalizer.detach(_decToken);
    _bufFinalizer.detach(_pcmToken);
    _bufFinalizer.detach(_bytesToken);
    final e = _enc, d = _dec;
    _enc = nullptr;
    _dec = nullptr;
    malloc.free(_pcm);
    malloc.free(_bytes);
    _encDestroyPtr.asFunction<void Function(Pointer<Void>)>()(e);
    _decDestroyPtr.asFunction<void Function(Pointer<Void>)>()(d);
  }
}
