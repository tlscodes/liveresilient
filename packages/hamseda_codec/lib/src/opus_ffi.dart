/// FFI binding to libopus 1.5.2 for the voice letter's Opus modes:
///   mode 12 — 6 kbit/s narrowband, hard CBR, 60 ms frames of 8 kHz s16:
///             45 B per frame, 750 B/s (the first Opus letter, 2026-09-21);
///   mode 6  — SILK VBR, 60 ms frames of 16 kHz s16, wideband from
///             9 kbit/s, one length byte per packet on the wire; the
///             recorder's fit loop picks the bitrate the ten letters allow
///             (about 10 kbit/s for 30 s). Decoded with NoLACE for the ear.
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

/// Mode 6 takes and gives 16 kHz PCM: SILK wideband keeps the 4-8 kHz
/// where Persian fricatives live.
const int opusWideSampleRate = 16000;
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

const int _opusBandwidthWideband = 1103;

/// One Opus tuning behind a wire mode. [cbr6kNb] is mode 12, byte-exact
/// with c60e475. [OpusVoiceConfig.vbr] is mode 6: 16 kHz PCM both ways,
/// SILK VBR, wideband from 9 kbit/s (libopus's own voice crossover,
/// opus_encoder.c:145: NB below 9000, WB above), narrowband below; the
/// decoder reads which from each packet's TOC, so one wire mode covers both.
class OpusVoiceConfig {
  const OpusVoiceConfig._({
    required this.sampleRate,
    required this.bitrate,
    required this.bandwidth,
    required this.vbr,
  });

  OpusVoiceConfig.vbr(int bitrate)
    : this._(
        sampleRate: opusWideSampleRate,
        bitrate: bitrate.clamp(6000, 16000),
        bandwidth: bitrate >= 9000
            ? _opusBandwidthWideband
            : _opusBandwidthNarrowband,
        vbr: true,
      );

  static const cbr6kNb = OpusVoiceConfig._(
    sampleRate: opusVoiceSampleRate,
    bitrate: opusVoiceBitrate,
    bandwidth: _opusBandwidthNarrowband,
    vbr: false,
  );

  final int sampleRate;
  final int bitrate;
  final int bandwidth;
  final bool vbr;

  /// 60 ms everywhere: least side-info per second, and OSCE still runs
  /// (osce.c:933 gates on the 20 ms SILK frame; dec_API.c:196 gives a
  /// 60 ms packet three of them).
  int get frameMs => opusVoiceFrameMs;
  int get samplesPerFrame => sampleRate * frameMs ~/ 1000;

  /// The fixed packet size in hard CBR, 0 when variable.
  int get cbrBytes => vbr ? 0 : bitrate * frameMs ~/ 8000;

  /// The largest packet the wire's one length byte can carry (255 B is
  /// 34 kbit/s for one 60 ms packet; libopus caps at max_data_bytes).
  int get maxPacketBytes => vbr ? 255 : cbrBytes;

  /// Scratch bytes handed to opus_encode as max_data_bytes.
  int get bufferBytes => vbr ? maxPacketBytes : cbrBytes * 2;
}

/// Opus encoder + decoder over 60 ms frames of s16 PCM at [config]'s rate;
/// one instance serves either direction. [decoderComplexity] 6 = LACE,
/// 7 = NoLACE (OSCE, compiled in by make_opus.sh): effective on a wideband
/// packet, inert on mode 12 (8 kHz SILK, measured byte-identical). The
/// digest witnesses compare complexity-0 decodes: OSCE is a float DNN whose
/// NEON and AVX kernels differ in the last bits, so a complexity-7 decode
/// is for the ear, never for a sha.
class OpusVoice implements VoiceFrameCodec, Finalizable {
  /// Mode 12, unchanged.
  OpusVoice({int decoderComplexity = 0})
    : this.configured(
        OpusVoiceConfig.cbr6kNb,
        decoderComplexity: decoderComplexity,
      );

  OpusVoice.configured(this.config, {int decoderComplexity = 0}) {
    final err = malloc<Int32>();
    try {
      _enc = _encCreate(config.sampleRate, 1, _opusApplicationVoip, err);
      if (_enc == nullptr || err.value != _opusOk) {
        throw StateError('opus_encoder_create failed: ${err.value}');
      }
      _encFinalizer.attach(this, _enc.cast(), detach: _encToken);
      _dec = _decCreate(config.sampleRate, 1, err);
      if (_dec == nullptr || err.value != _opusOk) {
        throw StateError('opus_decoder_create failed: ${err.value}');
      }
      _decFinalizer.attach(this, _dec.cast(), detach: _decToken);
    } finally {
      malloc.free(err);
    }
    // Order: bitrate, then VBR before its constraint, then MAX_BANDWIDTH
    // before BANDWIDTH (BANDWIDTH is clamped to the max in force).
    _check(_encCtl(_enc, _opusSetBitrate, config.bitrate), 'set bitrate');
    _check(_encCtl(_enc, _opusSetVbr, config.vbr ? 1 : 0), 'set vbr');
    // Unconstrained: a letter is a file, not a channel.
    _check(_encCtl(_enc, _opusSetVbrConstraint, 0), 'set vbr constraint');
    _check(_encCtl(_enc, _opusSetSignal, _opusSignalVoice), 'set signal');
    _check(_encCtl(_enc, _opusSetMaxBandwidth, config.bandwidth), 'set max bw');
    _check(_encCtl(_enc, _opusSetBandwidth, config.bandwidth), 'set bw');
    _check(_encCtl(_enc, _opusSetComplexity, 10), 'set complexity');
    _check(_encCtl(_enc, _opusSetInbandFec, 0), 'set fec');
    _check(_encCtl(_enc, _opusSetPacketLossPerc, 0), 'set loss');
    // The wire has no clock: a DTX gap is time no receiver can see.
    _check(_encCtl(_enc, _opusSetDtx, 0), 'set dtx');
    _check(_encCtl(_enc, _opusSetLsbDepth, 16), 'set lsb depth');
    if (decoderComplexity > 0) {
      _check(
        _decCtl(_dec, _opusSetComplexity, decoderComplexity),
        'set decoder complexity',
      );
    }
    _pcm = malloc<Int16>(config.samplesPerFrame);
    _bytes = malloc<Uint8>(config.bufferBytes);
    _bufFinalizer.attach(this, _pcm.cast(), detach: _pcmToken);
    _bufFinalizer.attach(this, _bytes.cast(), detach: _bytesToken);
  }

  final OpusVoiceConfig config;

  final Object _encToken = Object();
  final Object _decToken = Object();
  final Object _pcmToken = Object();
  final Object _bytesToken = Object();

  Pointer<Void> _enc = nullptr;
  Pointer<Void> _dec = nullptr;
  late final Pointer<Int16> _pcm;
  late final Pointer<Uint8> _bytes;

  @override
  int get sampleRate => config.sampleRate;

  @override
  int get samplesPerFrame => config.samplesPerFrame;

  /// 0 for the variable mode: the wire measures, it does not predict.
  @override
  int get bitsPerFrame => config.cbrBytes * 8;

  void _checkLive() {
    if (_enc == nullptr) throw StateError('OpusVoice used after dispose');
  }

  /// One 60 ms frame -> one Opus packet, TOC included: exactly
  /// [OpusVoiceConfig.cbrBytes] in CBR, 1..255 B in VBR.
  @override
  Uint8List encodeFrame(Int16List speech) {
    _checkLive();
    final want = config.samplesPerFrame;
    if (speech.length != want) {
      throw ArgumentError('need $want samples, got ${speech.length}');
    }
    _pcm.asTypedList(want).setAll(0, speech);
    final n = _encode(_enc, _pcm, want, _bytes, config.bufferBytes);
    if (n < 0) throw StateError('opus_encode failed: $n');
    if (config.vbr) {
      if (n < 1 || n > config.maxPacketBytes) {
        throw StateError(
          'opus_encode returned $n B, the wire carries 1..${config.maxPacketBytes}',
        );
      }
    } else if (n != config.cbrBytes) {
      throw StateError(
        'opus_encode returned $n B, the wire wants ${config.cbrBytes}',
      );
    }
    return Uint8List.fromList(_bytes.asTypedList(n));
  }

  /// One packet -> exactly [samplesPerFrame] samples; a packet of any
  /// other duration (foreign TOC) fails here, never plays at the wrong
  /// speed.
  @override
  Int16List decodeFrame(Uint8List packet) {
    _checkLive();
    final ok = config.vbr
        ? packet.isNotEmpty && packet.length <= config.maxPacketBytes
        : packet.length == config.cbrBytes;
    if (!ok) {
      throw ArgumentError(
        'packet of ${packet.length} B does not fit this mode',
      );
    }
    _bytes.asTypedList(packet.length).setAll(0, packet);
    final n = _decode(
      _dec,
      _bytes,
      packet.length,
      _pcm,
      config.samplesPerFrame,
      0,
    );
    if (n < 0) throw StateError('opus_decode failed: $n');
    if (n != config.samplesPerFrame) {
      throw StateError(
        'opus_decode returned $n samples, want ${config.samplesPerFrame}',
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
