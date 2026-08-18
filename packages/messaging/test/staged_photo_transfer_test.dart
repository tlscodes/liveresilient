@Timeout(Duration(minutes: 2))
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:messaging/messaging.dart';
import 'package:test/test.dart';

/// Mutually-paired lossy port — the shaped rig link in miniature, i.i.d.
/// drop with a deterministic seed, async delivery like the real doubles in
/// binary_stream_transfer_test.dart.
class _LossyPort implements DataChannelPort {
  _LossyPort(this.dropPerMille, int seed) : _rng = math.Random(seed);

  late _LossyPort peer;
  final int dropPerMille;
  final math.Random _rng;
  final _in = StreamController<List<int>>.broadcast(sync: true);

  @override
  Stream<List<int>> get inbound => _in.stream;

  @override
  Future<void> send(List<int> frame) async {
    if (_rng.nextInt(1000) < dropPerMille) return;
    final copy = List<int>.from(frame);
    Future<void>.delayed(Duration.zero, () {
      if (!peer._in.isClosed) peer._in.add(copy);
    });
  }

  @override
  Future<void> close() async {
    await _in.close();
  }
}

(_LossyPort, _LossyPort) _pair(int dropPerMille, {int seed = 42}) {
  final a = _LossyPort(dropPerMille, seed);
  final b = _LossyPort(dropPerMille, seed + 1);
  a.peer = b;
  b.peer = a;
  return (a, b);
}

Uint8List _bytes(int n, int seed) {
  final r = math.Random(seed);
  return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
}

Uint8List _gradientRgba(int w, int h) {
  final px = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final o = (y * w + x) * 4;
      px[o] = (255 * x / (w - 1)).round();
      px[o + 1] = (255 * y / (h - 1)).round();
      px[o + 2] = 128;
      px[o + 3] = 255;
    }
  }
  return px;
}

StagedPhotoArtifacts _artifacts({int originalBytes = 96 * 1024}) =>
    StagedPhotoArtifacts(
      thumbHash: ThumbHash.encodeRgba(64, 48, _gradientRgba(64, 48)),
      preview: _bytes(12 * 1024, 5),
      original: _bytes(originalBytes, 9),
      width: 2048,
      height: 1536,
    );

Future<void> _pump([int rounds = 40]) async {
  for (var i = 0; i < rounds; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  test('announcement codec round-trips; foreign text is left alone', () {
    final ann = PhotoAnnouncement.fromArtifacts(_artifacts());
    final back = PhotoAnnouncement.tryDecode(ann.encode());
    expect(back, isNotNull);
    expect(back!.photoId, ann.photoId);
    expect(back.sha256Hex, ann.sha256Hex);
    expect(back.previewId, ann.previewId);
    expect(back.sizeBytes, ann.sizeBytes);
    expect(back.thumbHash, equals(ann.thumbHash));

    expect(PhotoAnnouncement.tryDecode('سلام'), isNull);
    expect(PhotoAnnouncement.tryDecode('{"t":"attach","aid":"x"}'), isNull);
    expect(PhotoAnnouncement.tryDecode('{"t":"photo","v":9}'), isNull);
  });

  test(
      'CONTRACT: three rungs climb in order under 30% loss on the ARQ lane, '
      'original full-sha verified', () async {
    final (sp, rp) = _pair(300);
    final rx = StagedPhotoReceiver.arq(rp);
    final updates = <StagedPhotoUpdate>[];
    rx.updates.listen(updates.add);
    final tx = StagedPhotoSender.arq(
      sp,
      announce: (text) async => rx.offerText(text),
      retransmitAfter: const Duration(milliseconds: 60),
      chunkBytes: 4 * 1024,
    );
    final a = _artifacts();
    final res = await tx.deliver(a);
    await _pump();

    expect(updates.map((u) => u.stage).toList(), [
      PhotoStage.announced,
      PhotoStage.previewReady,
      PhotoStage.originalVerified,
    ]);
    final st = rx.photos[res.announcement.photoId]!;
    expect(st.sha256Verified, isTrue);
    expect(st.preview, equals(a.preview));
    expect(st.original, equals(a.original));
    expect(res.totalUnits, (a.original.length / (4 * 1024)).ceil());
    await rx.close();
  });

  test('CONTRACT: re-sending the same photo is answered from held bytes',
      () async {
    final (sp, rp) = _pair(300, seed: 7);
    final rx = StagedPhotoReceiver.arq(rp);
    final updates = <StagedPhotoUpdate>[];
    rx.updates.listen(updates.add);
    final tx = StagedPhotoSender.arq(
      sp,
      announce: (text) async => rx.offerText(text),
      retransmitAfter: const Duration(milliseconds: 60),
      chunkBytes: 4 * 1024,
    );
    final a = _artifacts();

    final sw1 = Stopwatch()..start();
    await tx.deliver(a);
    sw1.stop();
    await _pump();
    final updatesAfterFirst = updates.length;

    final sw2 = Stopwatch()..start();
    await tx.deliver(a);
    sw2.stop();
    await _pump();

    // The repeat announcement renders instantly from held rungs...
    final dedupUpdates = updates.sublist(updatesAfterFirst);
    expect(dedupUpdates, hasLength(1));
    expect(dedupUpdates.single.stage, PhotoStage.originalVerified);
    expect(dedupUpdates.single.deduplicated, isTrue);
    // ...and the lane answers both blobs from its completed-id cache
    // instead of re-shipping payload — measurably faster than the first
    // delivery even on the same lossy link.
    expect(sw2.elapsed, lessThan(sw1.elapsed));
    expect(sw2.elapsed, lessThan(const Duration(seconds: 2)),
        reason: 'dedup re-send must be answered without payload transfer');
    await rx.close();
  });

  test('CONTRACT: fountain lane climbs the ladder under 60% loss', () async {
    final (sp, rp) = _pair(600, seed: 11);
    final rx = StagedPhotoReceiver.fountain(
      rp,
      expireAfter: const Duration(seconds: 120),
    );
    final updates = <StagedPhotoUpdate>[];
    rx.updates.listen(updates.add);
    final tx = StagedPhotoSender.fountain(
      sp,
      announce: (text) async => rx.offerText(text),
      symbolBytes: 1024,
      floorBytesPerSec: 256 * 1024,
      staleAfter: const Duration(seconds: 60),
    );
    final a = _artifacts(originalBytes: 48 * 1024);
    final res = await tx.deliver(a);
    await _pump();

    expect(updates.map((u) => u.stage).toList(), [
      PhotoStage.announced,
      PhotoStage.previewReady,
      PhotoStage.originalVerified,
    ]);
    final st = rx.photos[res.announcement.photoId]!;
    expect(st.sha256Verified, isTrue);
    expect(st.original, equals(a.original));
    // Rateless overhead is loss, never a stall: symbols sent must at least
    // cover the source. (The exact ratio is the rig's business to judge.)
    expect(res.sentSymbols, greaterThanOrEqualTo(res.totalSourceSymbols));
    expect(res.totalSourceSymbols, 48);
    await rx.close();
  });

  test('a blob that beats its announcement is claimed on arrival', () async {
    final (sp, rp) = _pair(0, seed: 3);
    final rx = StagedPhotoReceiver.arq(rp);
    final updates = <StagedPhotoUpdate>[];
    rx.updates.listen(updates.add);
    String? heldAnnouncement;
    final tx = StagedPhotoSender.arq(
      sp,
      announce: (text) async => heldAnnouncement = text,
      retransmitAfter: const Duration(milliseconds: 40),
      chunkBytes: 4 * 1024,
    );
    final a = _artifacts(originalBytes: 16 * 1024);
    await tx.deliver(a);
    await _pump();
    expect(rx.photos, isEmpty,
        reason: 'no announcement yet — blobs wait in the orphan stash');

    expect(rx.offerText(heldAnnouncement!), isTrue);
    await _pump();
    expect(updates.map((u) => u.stage).toList(), [
      PhotoStage.announced,
      PhotoStage.previewReady,
      PhotoStage.originalVerified,
    ]);
    final st = rx.photos.values.single;
    expect(st.sha256Verified, isTrue);
    expect(st.original, equals(a.original));
    await rx.close();
  });

  test('tiny photo (preview == original) climbs both rungs from one blob',
      () async {
    final (sp, rp) = _pair(0, seed: 13);
    final rx = StagedPhotoReceiver.arq(rp);
    final updates = <StagedPhotoUpdate>[];
    rx.updates.listen(updates.add);
    final tx = StagedPhotoSender.arq(
      sp,
      announce: (text) async => rx.offerText(text),
      retransmitAfter: const Duration(milliseconds: 40),
      chunkBytes: 4 * 1024,
    );
    final tiny = _bytes(8 * 1024, 21);
    final a = StagedPhotoArtifacts(
      thumbHash: ThumbHash.encodeRgba(32, 32, _gradientRgba(32, 32)),
      preview: tiny,
      original: tiny,
      width: 640,
      height: 640,
    );
    expect(PhotoAnnouncement.fromArtifacts(a).singleBlob, isTrue);
    await tx.deliver(a);
    await _pump();
    expect(updates.map((u) => u.stage).toList(), [
      PhotoStage.announced,
      PhotoStage.originalVerified,
    ]);
    final st = rx.photos.values.single;
    expect(st.preview, equals(tiny));
    expect(st.original, equals(tiny));
    expect(st.sha256Verified, isTrue);
    await rx.close();
  });

  test('ordinary chat text is not consumed by the photo receiver', () {
    final (_, rp) = _pair(0, seed: 1);
    final rx = StagedPhotoReceiver.arq(rp);
    expect(rx.offerText('just a message'), isFalse);
    expect(rx.offerText('{"t":"attach","aid":"a","kind":"file","ct":"x",'
        '"i":0,"n":1,"d":""}'), isFalse);
  });
}
