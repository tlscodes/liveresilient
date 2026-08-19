/// Generates the six T3 wire payloads into tools/dossier/e2e_payloads/,
/// each byte-count pinned to its phase-5 source number:
///   text  29B  (h3 Text row p50)      codec framing + the measurer's exact
///                                     zstd CLI flags (-19 --single-thread
///                                     --no-check -D dict)
///   news  1160B (h3 NewsPage row)     encodeNewsPage + brotli CLI -q 11,
///                                     the measurer's compressor
///   voice 879B (h3 VoiceNote row)     c2enc 700C frames + encodeVoiceNote
///   photo 2682B (h3 Photo row)        the phase-5 artifact itself
///   video 5926B (h3 VideoNote row)    the phase-5 artifact itself
/// A payloads.tsv (name, bytes, sha256, source) sits next to them; the
/// device matrix test loads these files over the lane and decodes each.
///
/// Run from apps/reference_app:  dart run tool/gen_e2e_payloads.dart
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:broadcast_media/src/compact_news_codec.dart';
import 'package:hamseda_codec/src/voice_note_codec.dart';
import 'package:messaging/src/compact_text_codec.dart';

const _repo = '../..';
const _out = '$_repo/tools/dossier/e2e_payloads';

Uint8List _run(String exe, List<String> args) {
  final p = Process.runSync(exe, args,
      stdoutEncoding: null, stderrEncoding: null, environment: const {});
  if (p.exitCode != 0) {
    throw StateError('$exe ${args.join(' ')} -> ${p.exitCode}');
  }
  return Uint8List.fromList(p.stdout as List<int>);
}

Uint8List _zstdCli(Uint8List raw, String dictPath) {
  final tmp = Directory.systemTemp.createTempSync('t3z');
  try {
    File('${tmp.path}/in').writeAsBytesSync(raw);
    _run('zstd', [
      '-19', '--single-thread', '--no-check', '-D', dictPath, '-f',
      '${tmp.path}/in', '-o', '${tmp.path}/out',
    ]);
    return File('${tmp.path}/out').readAsBytesSync();
  } finally {
    tmp.deleteSync(recursive: true);
  }
}

Uint8List _brotliCli(Uint8List raw) {
  final tmp = Directory.systemTemp.createTempSync('t3b');
  try {
    File('${tmp.path}/in').writeAsBytesSync(raw);
    _run('brotli', ['-q', '11', '-f', '${tmp.path}/in', '-o', '${tmp.path}/out']);
    return File('${tmp.path}/out').readAsBytesSync();
  } finally {
    tmp.deleteSync(recursive: true);
  }
}

void main() {
  Directory(_out).createSync(recursive: true);
  final rows = <List<String>>[];

  void emit(String name, Uint8List bytes, int mustBe, String source) {
    if (bytes.length != mustBe) {
      throw StateError('$name is ${bytes.length}B, phase-5 source says '
          '$mustBe B — construction drifted, refusing to write');
    }
    File('$_out/$name').writeAsBytesSync(bytes);
    final sha = ascii
        .decode(_run('shasum', ['-a', '256', '$_out/$name']))
        .split(' ')
        .first;
    rows.add([name, '${bytes.length}', sha, source]);
    stdout.writeln('wrote $name ${bytes.length}B');
  }

  // ---- text 29B: first corpus message whose codec frame lands on the p50
  const dictPath = '$_repo/packages/messaging/assets/zstd_chat.dict';
  final corpus = File('$_repo/tools/phase5/corpus/chat_corpus_200.jsonl')
      .readAsLinesSync();
  Uint8List? textWire;
  int? textId;
  for (final line in corpus) {
    final m = jsonDecode(line) as Map<String, dynamic>;
    final frame = encodeCompactText(
      utf8Text: Uint8List.fromList(utf8.encode(m['text'] as String)),
      msgId: (m['id'] as int) & 0xFFFF,
      dictVer: 1,
      compress: (raw) => _zstdCli(raw, dictPath),
    );
    if (frame.bytes.length == 29) {
      textWire = frame.bytes;
      textId = m['id'] as int;
      break;
    }
  }
  if (textWire == null) {
    throw StateError('no corpus message frames to exactly 29B');
  }
  emit('text_29b.bin', textWire, 29,
      'h3 Text p50; corpus msg id=$textId; measurer zstd flags');

  // ---- news 1160B: the reference page through the codec + CLI brotli
  final page =
      jsonDecode(File('$_repo/tools/phase5/corpus/news_ref_page.json')
          .readAsStringSync()) as Map<String, Object?>;
  emit('news_1160b.bin', encodeNewsPage(page, _brotliCli), 1160,
      'h3 NewsPage; corpus news_ref_page.json; brotli -q 11');

  // ---- voice 879B: c2enc 700C frames -> tight bit-pack via the codec
  final voiceTmp = Directory.systemTemp.createTempSync('t3v');
  try {
    final wav = File('$_repo/tools/phase5/corpus/speech_ref_10s.wav')
        .readAsBytesSync();
    // 16kHz mono s16 wav, 44B canonical header from the phase-5 builder;
    // c2enc wants 8kHz raw — the phase-5 measurer downsampled with sox/ffmpeg.
    File('${voiceTmp.path}/in.wav').writeAsBytesSync(wav);
    _run('ffmpeg', [
      '-loglevel', 'error', '-y', '-i', '${voiceTmp.path}/in.wav',
      '-ar', '8000', '-ac', '1', '-f', 's16le', '${voiceTmp.path}/in.raw',
    ]);
    _run('$_repo/tools/phase5/native/codec2_450/build/src/c2enc',
        ['700C', '${voiceTmp.path}/in.raw', '${voiceTmp.path}/enc.bit']);
    final bits = File('${voiceTmp.path}/enc.bit').readAsBytesSync();
    if (bits.length % 4 != 0) {
      throw StateError('c2enc .bit not 4B-framed: ${bits.length}');
    }
    final frames = <Uint8List>[
      for (var i = 0; i < bits.length; i += 4)
        Uint8List.sublistView(bits, i, i + 4)
    ];
    emit(
        'voice_879b.bin',
        packVoiceNote(frames: frames, mode: VoiceNoteMode.c700),
        879,
        'h3 VoiceNote; c2enc 700C of speech_ref_10s.wav; codec bit-pack');
  } finally {
    voiceTmp.deleteSync(recursive: true);
  }

  // ---- photo + video: the phase-5 artifacts verbatim
  emit(
      'photo_2682b.avif',
      File('$_repo/tools/phase5/artifacts/photo_ref_3k.avif').readAsBytesSync(),
      2682,
      'h3 Photo; artifact photo_ref_3k.avif');
  emit(
      'video_5926b.bin',
      File('$_repo/tools/phase5/artifacts/video_note_15k.bin').readAsBytesSync(),
      5926,
      'h3 VideoNote; artifact video_note_15k.bin');

  final tsv = StringBuffer('name\tbytes\tsha256\tsource\n');
  for (final r in rows) {
    tsv.writeln(r.join('\t'));
  }
  File('$_out/payloads.tsv').writeAsStringSync(tsv.toString());
  stdout.writeln('payloads.tsv written (${rows.length} rows)');
}
