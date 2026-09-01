/// High-level AV1 decode over the generated dav1d bindings (FULL_TEST_PLAN
/// T3: VideoNote "decode all frames" and Photo "decode and render" rows).
///
/// Input is what this repo's wire formats carry: raw AV1 temporal units
/// (video_note_codec's frame list, or the mdat payload of our AVIF photos).
/// Output is 8-bit RGBA, converted from the decoder's I420 with BT.601
/// limited-range integer math — enough for rendering and pixel assertions.
///
/// Library resolution mirrors the other bindings: DAV1D_LIB_PATH env var,
/// the app-bundled dav1d.framework on iOS, then the host brew dylib.
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'generated/dav1d_bindings.dart';

DynamicLibrary _open() {
  final env = Platform.environment['DAV1D_LIB_PATH'];
  if (env != null && env.isNotEmpty) return DynamicLibrary.open(env);
  if (Platform.isIOS) return DynamicLibrary.open('dav1d.framework/dav1d');
  for (final p in [
    '/usr/local/opt/dav1d/lib/libdav1d.dylib',
    '/opt/homebrew/opt/dav1d/lib/libdav1d.dylib',
    // Linux: same reasoning as brotli — versioned soname first.
    '/usr/lib/x86_64-linux-gnu/libdav1d.so.7',
    '/usr/lib/x86_64-linux-gnu/libdav1d.so',
    '/usr/lib/aarch64-linux-gnu/libdav1d.so.7',
    '/usr/lib/aarch64-linux-gnu/libdav1d.so',
  ]) {
    if (File(p).existsSync()) return DynamicLibrary.open(p);
  }
  return DynamicLibrary.process();
}

final Dav1dBindings _b = Dav1dBindings(_open());

/// -EAGAIN on darwin (35) and linux (11); dav1d returns negative errnos.
const _again = {-35, -11};

class DecodedFrame {
  DecodedFrame(this.width, this.height, this.rgba);
  final int width;
  final int height;
  final Uint8List rgba;
}

class MalformedAv1Stream implements Exception {
  MalformedAv1Stream(this.message);
  final String message;
  @override
  String toString() => 'MalformedAv1Stream($message)';
}

int _clamp8(int v) => v < 0 ? 0 : (v > 255 ? 255 : v);

DecodedFrame _pictureToRgba(Pointer<Dav1dPicture> pic) {
  final p = pic.ref;
  // uplift 2026-08-19 (T4), assumed->proven: this converter used to run
  // I420 math on ANY layout, silently garbling chroma — and the guard that
  // replaced the assumption immediately caught a real case (avifenc emits
  // our photos as I444). Now the layout drives the chroma subsampling
  // shifts and anything outside the four 8-bit layouts fails loud.
  if (p.p.bpc != 8) {
    throw MalformedAv1Stream('unsupported bpc=${p.p.bpc} (converter is 8-bit)');
  }
  final (ssHor, ssVer, hasChroma) = switch (p.p.layout) {
    Dav1dPixelLayout.DAV1D_PIXEL_LAYOUT_I420 => (1, 1, true),
    Dav1dPixelLayout.DAV1D_PIXEL_LAYOUT_I422 => (1, 0, true),
    Dav1dPixelLayout.DAV1D_PIXEL_LAYOUT_I444 => (0, 0, true),
    Dav1dPixelLayout.DAV1D_PIXEL_LAYOUT_I400 => (0, 0, false),
  };
  final w = p.p.w, h = p.p.h;
  final y = p.data[0].cast<Uint8>();
  final u = hasChroma ? p.data[1].cast<Uint8>() : nullptr.cast<Uint8>();
  final v = hasChroma ? p.data[2].cast<Uint8>() : nullptr.cast<Uint8>();
  final ys = p.stride[0], cs = p.stride[1];
  final rgba = Uint8List(w * h * 4);
  var o = 0;
  for (var r = 0; r < h; r++) {
    for (var c = 0; c < w; c++) {
      final yy = y[r * ys + c];
      final uu = hasChroma ? u[(r >> ssVer) * cs + (c >> ssHor)] : 128;
      final vv = hasChroma ? v[(r >> ssVer) * cs + (c >> ssHor)] : 128;
      // BT.601 limited range, integer form
      final c298 = 298 * (yy - 16);
      rgba[o++] = _clamp8((c298 + 409 * (vv - 128) + 128) >> 8);
      rgba[o++] = _clamp8(
        (c298 - 100 * (uu - 128) - 208 * (vv - 128) + 128) >> 8,
      );
      rgba[o++] = _clamp8((c298 + 516 * (uu - 128) + 128) >> 8);
      rgba[o++] = 255;
    }
  }
  return DecodedFrame(w, h, rgba);
}

/// Decodes a list of AV1 temporal units (one per frame) to RGBA frames.
List<DecodedFrame> decodeAv1Frames(List<Uint8List> temporalUnits) {
  final settings = calloc<Dav1dSettings>();
  final ctxP = calloc<Pointer<Dav1dContext>>();
  _b.dav1d_default_settings(settings);
  var rc = _b.dav1d_open(ctxP, settings);
  if (rc != 0) {
    calloc.free(settings);
    calloc.free(ctxP);
    throw MalformedAv1Stream('dav1d_open failed rc=$rc');
  }
  final ctx = ctxP.value;
  final out = <DecodedFrame>[];
  final data = calloc<Dav1dData>();
  final pic = calloc<Dav1dPicture>();
  try {
    void drain({required bool eof}) {
      for (;;) {
        rc = _b.dav1d_get_picture(ctx, pic);
        if (rc == 0) {
          out.add(_pictureToRgba(pic));
          _b.dav1d_picture_unref(pic);
        } else if (_again.contains(rc)) {
          if (eof) break;
          return; // feed more input first
        } else {
          throw MalformedAv1Stream('dav1d_get_picture rc=$rc');
        }
        if (eof) continue;
        return;
      }
    }

    for (final tu in temporalUnits) {
      final buf = _b.dav1d_data_create(data, tu.length);
      if (buf == nullptr) throw MalformedAv1Stream('dav1d_data_create failed');
      buf.cast<Uint8>().asTypedList(tu.length).setAll(0, tu);
      for (;;) {
        rc = _b.dav1d_send_data(ctx, data);
        if (rc == 0) break;
        if (_again.contains(rc)) {
          drain(eof: false);
          continue;
        }
        _b.dav1d_data_unref(data);
        throw MalformedAv1Stream('dav1d_send_data rc=$rc');
      }
      drain(eof: false);
    }
    drain(eof: true);
    return out;
  } finally {
    _b.dav1d_close(ctxP);
    calloc.free(pic);
    calloc.free(data);
    calloc.free(settings);
    calloc.free(ctxP);
  }
}

/// Minimal ISOBMFF walk for OUR avif photos (single-item, avifenc-produced,
/// metadata stripped by the phase-5 measurer): returns the mdat payload,
/// which is the item's AV1 temporal unit.
Uint8List avifMdatPayload(Uint8List avif) {
  var off = 0;
  final bd = ByteData.sublistView(avif);
  while (off + 8 <= avif.length) {
    var size = bd.getUint32(off);
    final type = String.fromCharCodes(avif.sublist(off + 4, off + 8));
    var header = 8;
    if (size == 1) {
      if (off + 16 > avif.length) break;
      size = bd.getUint64(off + 8);
      header = 16;
    } else if (size == 0) {
      size = avif.length - off;
    }
    if (size < header || off + size > avif.length) {
      throw MalformedAv1Stream('bad box $type at $off');
    }
    if (type == 'mdat') {
      return Uint8List.sublistView(avif, off + header, off + size);
    }
    off += size;
  }
  throw MalformedAv1Stream('no mdat box');
}
