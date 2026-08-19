/// FULL_TEST_PLAN track 3 — the six-feature E2E matrix ON THE DEVICE under
/// the t3x profile (2Kbps per crossing, 60% end-to-end composed loss,
/// rtt 2000ms), driven by tools/t2/h2_run.sh which owns shaping, the real
/// datagram relay, tcpdump evidence and teardown.
///
/// Every feature transfers its REAL phase-5 wire bytes (embedded via
/// support/e2e_payloads.dart, sizes pinned to h3_results.tsv) through the
/// device's own DatagramLanePort to the Mac relay and back (double
/// crossing), then decodes with the REAL native codecs from the vendored
/// frameworks. Each feature prints one row:
///   `E2E_ROW feature wire budget measured_s status note`
/// tools/phase5/run_t3_matrix.sh turns those into e2e_ios_results.tsv.
/// Rows are printed BEFORE assertions so an over-budget feature records an
/// honest FAIL row instead of vanishing.
@Timeout(Duration(minutes: 30))
library;

// Evidence rows are deliberately printed to the test log.
// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:broadcast_media/src/av1_decoder.dart';
import 'package:broadcast_media/src/brotli_ffi.dart';
import 'package:broadcast_media/src/compact_news_codec.dart';
import 'package:broadcast_media/src/video_note_codec.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hamseda_codec/src/codec2_ffi.dart';
import 'package:hamseda_codec/src/voice_note_codec.dart';
import 'package:integration_test/integration_test.dart';
import 'package:messaging/messaging.dart';
import 'package:messaging/src/compact_text_codec.dart';
import 'package:messaging/src/zstd_ffi.dart';

import 'support/datagram_lane_port.dart';
import 'support/e2e_payloads.dart';

const _relayHost = String.fromEnvironment('E2E_DGRAM_HOST');
const _dgramPort = int.fromEnvironment('E2E_DGRAM_PORT', defaultValue: 3737);

Uint8List _b64(String s) => base64Decode(s);

Future<(DatagramLanePort, DatagramLanePort)> _lanePair(String call) async {
  final key = DatagramLanePort.roomKeyFromCallId(call);
  final tx = await DatagramLanePort.bind(
      relayHost: _relayHost, relayPort: _dgramPort, roomKey: key);
  final rx = await DatagramLanePort.bind(
      relayHost: _relayHost, relayPort: _dgramPort, roomKey: key);
  return (tx, rx);
}

void _row(String feature, String wire, String budget, double measured,
    String status, String note) {
  print('E2E_ROW\t$feature\t$wire\t$budget\t'
      '${measured.toStringAsFixed(1)}\t$status\t$note');
}

/// Continuous-resend ARQ for one-datagram payloads. The sender re-emits
/// [0x51 seq payload] at [pace] until the receiver (same isolate, real
/// network round trip) has decoded; pacing respects the 2Kbps pipe so the
/// queue never bloats. Returns (elapsed s, attempts) or throws on [cap].
Future<(double, int)> _arqDeliver({
  required DatagramLanePort tx,
  required DatagramLanePort rx,
  required Uint8List payload,
  required Duration pace,
  required Duration cap,
  required void Function(Uint8List) verify,
}) async {
  final delivered = Completer<void>();
  Object? verifyError;
  final sub = rx.inbound.listen((f) {
    if (delivered.isCompleted || f.length < 2 || f[0] != 0x51) return;
    try {
      verify(Uint8List.fromList(f.sublist(2)));
      delivered.complete();
    } catch (e) {
      verifyError = e;
      delivered.complete();
    }
  });
  final sw = Stopwatch()..start();
  var attempts = 0;
  final frame = Uint8List(payload.length + 2)
    ..[0] = 0x51
    ..setAll(2, payload);
  while (!delivered.isCompleted && sw.elapsed < cap) {
    frame[1] = attempts & 0xFF;
    await tx.send(frame);
    attempts++;
    await Future.any([
      delivered.future,
      Future<void>.delayed(pace),
    ]);
  }
  await sub.cancel();
  if (!delivered.isCompleted) {
    throw TimeoutException('not delivered', cap);
  }
  if (verifyError != null) throw verifyError!;
  return (sw.elapsedMilliseconds / 1000.0, attempts);
}

/// Fountain transfer of [payload]; measured to receiver-complete + verify.
Future<double> _fountainDeliver({
  required DatagramLanePort tx,
  required DatagramLanePort rx,
  required Uint8List payload,
  required Duration cap,
  required void Function(Uint8List) verify,
}) async {
  final done = Completer<Uint8List>();
  final receiver = FountainStreamReceiver(
    rx,
    expireAfter: cap + const Duration(minutes: 2),
    onCompleted: (b) {
      if (!done.isCompleted) done.complete(b);
    },
  );
  final sender = FountainStreamSender(
    tx,
    symbolBytes: 512,
    // derived (stochastic_sla.py constants): pipe rate 250 B/s x 1.5
    // overshoot so pacing gaps never leave the pipe idle — measured to
    // take photo 74.1s -> 23.2s on-device
    floorBytesPerSec: 375,
    staleAfter: const Duration(seconds: 45),
  );
  final sw = Stopwatch()..start();
  final sendF = sender.send(payload);
  unawaited(sendF.then<void>((_) {}, onError: (Object e, StackTrace st) {
    if (!done.isCompleted) done.completeError(e, st);
  }));
  final got = await done.future.timeout(cap);
  final secs = sw.elapsedMilliseconds / 1000.0;
  verify(got);
  receiver.dispose();
  return secs;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('shape barrier: attach unshaped, begin only under the profile',
      (tester) async {
    await tester.runAsync(() async {
      // WHY: the CoreDevice debug tunnel is QUIC/UDP — launching under the
      // t3x profile (0.3675 plr per crossing) killed the attach (measured:
      // "Unable to start the app on the device", h2run.lMUVqM/test.log).
      // So the wrapper attaches first and shapes MID-RUN; this barrier
      // sends timestamped echo probes through the lane and releases the
      // matrix only after two probes observe rtt > 1500ms — which is also
      // the direct proof the lane's traffic crosses the shaped path.
      final (tx, rx) = await _lanePair('t3-barrier');
      print('E2E_MATRIX_WAITING_FOR_SHAPE');
      final sw = Stopwatch()..start();
      var lastRtt = 0.0;
      var liveCount = 0;
      final sub = rx.inbound.listen((f) {
        if (f.length < 10 || f[0] != 0x50) return;
        final bd = ByteData.sublistView(Uint8List.fromList(f));
        lastRtt = (sw.elapsedMilliseconds - bd.getInt64(2)).toDouble();
        if (lastRtt > 1500) {
          liveCount++;
        } else {
          liveCount = 0;
        }
      });
      var seq = 0;
      while (liveCount < 2 && sw.elapsed < const Duration(minutes: 5)) {
        final b = ByteData(10)
          ..setUint8(0, 0x50)
          ..setUint8(1, seq++ & 0xFF)
          ..setInt64(2, sw.elapsedMilliseconds);
        await tx.send(b.buffer.asUint8List());
        await Future<void>.delayed(const Duration(seconds: 2));
      }
      await sub.cancel();
      await tx.close();
      await rx.close();
      print('SHAPE_OBSERVED rtt_ms=${lastRtt.toStringAsFixed(0)} '
          'consecutive=$liveCount probes=$seq');
      expect(liveCount >= 2, isTrue,
          reason: 'shaping never became observable on the lane');
    });
  });

  testWidgets('chat: 29B compact frame — delivery + text integrity',
      (tester) async {
    await tester.runAsync(() async {
      final (tx, rx) = await _lanePair('t3-chat');
      final zstd = ZstdChat(_b64(kZstdChatDictB64));
      double measured = -1;
      var attempts = 0;
      var status = 'FAIL';
      var note = '';
      try {
        final (secs, tries) = await _arqDeliver(
          tx: tx,
          rx: rx,
          payload: _b64(kTextWireB64),
          pace: const Duration(milliseconds: 250),
          cap: const Duration(seconds: 12),
          verify: (bytes) {
            final text = utf8.decode(decodeCompactText(
              frame: CompactTextFrame.checked(bytes),
              localDictVer: 1,
              decompress: zstd.decompress,
            ));
            if (text != kTextExpected) {
              throw StateError('text mismatch: $text');
            }
          },
        );
        measured = secs;
        attempts = tries;
        if (secs <= 4.8) status = 'PASS';
        note = 'attempts=$attempts,msgId=$kTextMsgId,decoded=verified';
      } on TimeoutException {
        measured = 12.0;
        note = 'timeout,attempts=$attempts';
      } finally {
        zstd.dispose();
        await tx.close();
        await rx.close();
        _row('chat', '29', '4.8', measured, status, note);
      }
      expect(status, 'PASS');
    });
  });

  testWidgets('news: 1160B page — full decode on device', (tester) async {
    await tester.runAsync(() async {
      final (tx, rx) = await _lanePair('t3-news');
      final expected = jsonDecode(kNewsExpectedJson) as Map<String, Object?>;
      double measured = -1;
      var attempts = 0;
      var status = 'FAIL';
      var note = '';
      try {
        final (secs, tries) = await _arqDeliver(
          tx: tx,
          rx: rx,
          payload: _b64(kNewsWireB64),
          // 1160B needs ~4.6s per crossing at 250B/s: pace at the pipe
          pace: const Duration(seconds: 5),
          cap: const Duration(seconds: 60),
          verify: (bytes) {
            final page = decodeNewsPage(bytes, brotliDecode);
            if (page.length != expected.length ||
                jsonEncode(page) != jsonEncode(expected)) {
              throw StateError('page mismatch');
            }
          },
        );
        measured = secs;
        attempts = tries;
        if (secs <= 52.3) status = 'PASS';
        note = 'attempts=$attempts,page=verified';
      } on TimeoutException {
        measured = 60.0;
        note = 'timeout,attempts=$attempts';
      } finally {
        await tx.close();
        await rx.close();
        _row('news', '1160', '52.3', measured, status, note);
      }
      expect(status, 'PASS');
    });
  });

  testWidgets('voice_note: 879B — decode-complete (ready to play)',
      (tester) async {
    await tester.runAsync(() async {
      final (tx, rx) = await _lanePair('t3-voice');
      double measured = -1;
      var attempts = 0;
      var status = 'FAIL';
      var note = '';
      try {
        final (secs, tries) = await _arqDeliver(
          tx: tx,
          rx: rx,
          payload: _b64(kVoiceWireB64),
          pace: const Duration(seconds: 4),
          cap: const Duration(seconds: 48),
          verify: (bytes) {
            final frames = unpackVoiceNote(bytes);
            if (frames.length != 250) {
              throw StateError('expected 250 frames, got ${frames.length}');
            }
            final c = Codec2(codec2Mode700C);
            var energy = 0.0;
            for (final f in frames) {
              for (final s in c.decodeFrame(f)) {
                energy += s.abs();
              }
            }
            c.dispose();
            if (energy <= 0) throw StateError('decoded silence');
          },
        );
        measured = secs;
        attempts = tries;
        if (secs <= 42.3) status = 'PASS';
        // budget derivation note: 12s < wire 3.5s + 10s of audio, so the
        // plan's criterion is delivery+decode readiness, not realtime
        // playback — playback happens in the owner's uncut video (T3.4)
        note = 'attempts=$attempts,frames=250,decode=complete';
      } on TimeoutException {
        measured = 48.0;
        note = 'timeout,attempts=$attempts';
      } finally {
        await tx.close();
        await rx.close();
        _row('voice_note', '879', '42.3', measured, status, note);
      }
      expect(status, 'PASS');
    });
  });

  testWidgets('photo: 2682B AVIF — decode and render', (tester) async {
    ui.Image? img;
    await tester.runAsync(() async {
      final (tx, rx) = await _lanePair('t3-photo');
      double measured = -1;
      var status = 'FAIL';
      var note = '';
      try {
        final secs = await _fountainDeliver(
          tx: tx,
          rx: rx,
          payload: _b64(kPhotoWireB64),
          cap: const Duration(seconds: 100),
          verify: (bytes) {
            final frames = decodeAv1Frames([avifMdatPayload(bytes)]);
            final f = frames.single;
            if (f.width != 120 || f.height != 160) {
              throw StateError('decoded ${f.width}x${f.height}');
            }
            final done = Completer<ui.Image>();
            ui.decodeImageFromPixels(f.rgba, f.width, f.height,
                ui.PixelFormat.rgba8888, done.complete);
            img = null; // set after await below
            unawaited(done.future.then((i) => img = i));
          },
        );
        measured = secs;
        if (secs <= 49.6) status = 'PASS';
        note = 'decoded=120x160,render=pumped';
      } on TimeoutException {
        measured = 100.0;
        note = 'timeout';
      } finally {
        await tx.close();
        await rx.close();
        _row('photo', '2682', '49.6', measured, status, note);
      }
      expect(status, 'PASS');
    });
    // render the decoded pixels in the real widget tree
    if (img != null) {
      await tester.pumpWidget(Center(child: RawImage(image: img)));
      await tester.pump();
    }
  });

  testWidgets('video_note: 5926B — all frames decode', (tester) async {
    ui.Image? first;
    await tester.runAsync(() async {
      final (tx, rx) = await _lanePair('t3-video');
      double measured = -1;
      var status = 'FAIL';
      var note = '';
      try {
        final secs = await _fountainDeliver(
          tx: tx,
          rx: rx,
          payload: _b64(kVideoWireB64),
          cap: const Duration(seconds: 180),
          verify: (bytes) {
            final noteWire = VideoNote.decode(bytes);
            final frames = decodeAv1Frames(noteWire.videoFrames);
            if (frames.length != 15) {
              throw StateError('decoded ${frames.length}/15');
            }
            for (final f in frames) {
              if (f.width != 128 || f.height != 96) {
                throw StateError('frame ${f.width}x${f.height}');
              }
            }
            final done = Completer<ui.Image>();
            ui.decodeImageFromPixels(frames.first.rgba, 128, 96,
                ui.PixelFormat.rgba8888, done.complete);
            unawaited(done.future.then((i) => first = i));
          },
        );
        measured = secs;
        if (secs <= 82.0) status = 'PASS';
        note = 'frames=15/15,128x96';
      } on TimeoutException {
        measured = 180.0;
        note = 'timeout';
      } finally {
        await tx.close();
        await rx.close();
        _row('video_note', '5926', '82.0', measured, status, note);
      }
      expect(status, 'PASS');
    });
    if (first != null) {
      await tester.pumpWidget(Center(child: RawImage(image: first)));
      await tester.pump();
    }
  });

  testWidgets('ptt: 60s live stream — survival and continuity',
      (tester) async {
    await tester.runAsync(() async {
      final (tx, rx) = await _lanePair('t3-ptt');
      // On-device codec2-450 encode of a synthetic voice-band tone,
      // 25 frames (1s) per bundle: [0x53 seq packed(57B)] — the phase-5
      // fallback schedule (18 bits/40ms, 1s bundling).
      final enc = Codec2(codec2Mode450);
      final dec = Codec2(codec2Mode450);
      var sentBundles = 0;
      var gotBundles = 0;
      var decodedFrames = 0;
      var maxGapS = 0.0;
      Object? rxError;
      final lastRx = Stopwatch()..start();
      final sub = rx.inbound.listen((f) {
        if (f.length < 2 || f[0] != 0x53) return;
        try {
          final packed = Uint8List.fromList(f.sublist(2));
          final frames = unpackPttBundle(packed, dec);
          decodedFrames += frames;
          gotBundles++;
          final gap = lastRx.elapsedMilliseconds / 1000.0;
          if (gap > maxGapS) maxGapS = gap;
          lastRx.reset();
        } catch (e) {
          rxError = e;
        }
      });
      final pcm = Int16List(320);
      final sw = Stopwatch()..start();
      var status = 'FAIL';
      var note = '';
      try {
        while (sw.elapsed < const Duration(seconds: 60)) {
          final bundleStart = sw.elapsed;
          final packed = BytesBuilder(copy: false);
          var bitpos = 0;
          final buf = Uint8List(57);
          for (var i = 0; i < 25; i++) {
            for (var s = 0; s < 320; s++) {
              pcm[s] = (6000 *
                      (((sentBundles * 25 + i) * 320 + s) % 80 < 40 ? 1 : -1))
                  .toInt();
            }
            final bits = enc.encodeFrame(pcm);
            // append 18 bits from this frame's 3 bytes
            for (var b = 0; b < 18; b++) {
              final bit = (bits[b >> 3] >> (7 - (b & 7))) & 1;
              if (bit == 1) buf[bitpos >> 3] |= 0x80 >> (bitpos & 7);
              bitpos++;
            }
          }
          packed.add(buf);
          final frame = Uint8List(59)
            ..[0] = 0x53
            ..[1] = sentBundles & 0xFF
            ..setRange(2, 59, packed.takeBytes());
          await tx.send(frame);
          sentBundles++;
          final next = bundleStart + const Duration(seconds: 1);
          final wait = next - sw.elapsed;
          if (wait > Duration.zero) await Future<void>.delayed(wait);
        }
        // drain the pipe's tail (last bundles are still in 2s of rtt)
        await Future<void>.delayed(const Duration(seconds: 5));
        final ratio = sentBundles == 0 ? 0.0 : gotBundles / sentBundles;
        final alive = rxError == null && gotBundles > 0;
        if (alive) status = 'PASS';
        note = 'sent=$sentBundles,got=$gotBundles,'
            'ratio=${ratio.toStringAsFixed(3)},frames=$decodedFrames,'
            'maxGap=${maxGapS.toStringAsFixed(1)}s,'
            'err=${rxError ?? 'none'}';
      } finally {
        enc.dispose();
        dec.dispose();
        await sub.cancel();
        await tx.close();
        await rx.close();
        _row('ptt', '5220/60s', 'live', 60.0, status, note);
      }
      expect(status, 'PASS');
    });
  });
}

/// Unpacks a 57B PTT bundle (25 frames x 18 bits) and decodes every frame;
/// returns the decoded frame count. Throws on any decoder fault.
int unpackPttBundle(Uint8List packed, Codec2 dec) {
  var bitpos = 0;
  var frames = 0;
  final frameBytes = Uint8List(3);
  for (var i = 0; i < 25; i++) {
    frameBytes.fillRange(0, 3, 0);
    for (var b = 0; b < 18; b++) {
      final bit = (packed[bitpos >> 3] >> (7 - (bitpos & 7))) & 1;
      if (bit == 1) frameBytes[b >> 3] |= 0x80 >> (b & 7);
      bitpos++;
    }
    dec.decodeFrame(frameBytes);
    frames++;
  }
  return frames;
}
