import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'binary_stream_transfer.dart';
import 'data_channel_port.dart';
import 'fountain_stream_transfer.dart';
import 'thumb_hash.dart';

/// Staged photo delivery — «تحویل پلکانی» (RIG_GUIDE §0.2 item 1).
///
/// Three display rungs ride two channels:
///
///   rung 0, instant: a ~30-byte [ThumbHash] INSIDE the announcement text,
///     delivered by the reliable chat path like any message — the bubble
///     shows a blurred placeholder immediately, even under 60% loss.
///   rung 1, first seconds: a small preview (~15 KB) on the binary lane.
///   rung 2: the capped re-encoded original (2048px q80 by app contract),
///     content-addressed and verified against the FULL sha256 carried in
///     the announcement — the bubble's verified badge.
///
/// The lane is either the ARQ stream (healthy links) or the fountain
/// stream (loss >= 0.3) — the same switch the video row proved on the
/// datagram transport. This module does not pick; the caller passes the
/// decision with its ports.
///
/// Content addressing (sha256(content)[0:16] == lane transferId) is what
/// makes dedup and resume free: re-offering bytes the far side already
/// holds is answered from the lane's completed-id cache without a single
/// payload frame, and a torn transfer resumes from the HAVE/STATE bitmap.
///
/// Stage ORDER is part of the contract: the preview transfer completes
/// before the original's first frame is offered, so a live receiver climbs
/// the ladder in order — announced, previewReady, originalVerified — and
/// the package test gate pins exactly that order under loss.

enum StagedPhotoLane { arq, fountain }

enum PhotoStage { announced, previewReady, originalVerified }

/// The three pre-encoded artifacts. ENCODING is the app's duty (it owns
/// image codecs); this package owns delivery. [thumbHash] must stay small
/// enough to ride inside a chat message (hard cap 64 bytes).
class StagedPhotoArtifacts {
  final Uint8List thumbHash;
  final Uint8List preview;
  final Uint8List original;
  final int width;
  final int height;
  final String contentType;

  StagedPhotoArtifacts({
    required this.thumbHash,
    required this.preview,
    required this.original,
    required this.width,
    required this.height,
    this.contentType = 'image/jpeg',
  }) {
    if (thumbHash.length > 64) {
      throw ArgumentError('thumbHash must ride inside the announcement '
          '(<= 64 bytes, got ${thumbHash.length})');
    }
    if (original.isEmpty) throw ArgumentError('original must not be empty');
    if (preview.isEmpty) throw ArgumentError('preview must not be empty');
  }
}

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

Uint8List _id16(List<int> content) =>
    Uint8List.fromList(sha256.convert(content).bytes.sublist(0, 16));

/// The rung-0 chat message: everything the receiving bubble needs to render
/// NOW (thumbhash, dimensions) plus the content addresses that let it claim
/// the two binary rungs when they land.
class PhotoAnnouncement {
  static const String _tag = 'photo';

  final String photoId; // hex sha256(original)[0:16] == lane transferId
  final String sha256Hex; // FULL sha256 of original — the verified badge
  final String previewId; // hex sha256(preview)[0:16]
  final int sizeBytes;
  final int previewBytes;
  final int width;
  final int height;
  final String contentType;
  final Uint8List thumbHash;

  PhotoAnnouncement({
    required this.photoId,
    required this.sha256Hex,
    required this.previewId,
    required this.sizeBytes,
    required this.previewBytes,
    required this.width,
    required this.height,
    required this.contentType,
    required this.thumbHash,
  });

  factory PhotoAnnouncement.fromArtifacts(StagedPhotoArtifacts a) {
    return PhotoAnnouncement(
      photoId: _hex(_id16(a.original)),
      sha256Hex: _hex(sha256.convert(a.original).bytes),
      previewId: _hex(_id16(a.preview)),
      sizeBytes: a.original.length,
      previewBytes: a.preview.length,
      width: a.width,
      height: a.height,
      contentType: a.contentType,
      thumbHash: a.thumbHash,
    );
  }

  /// True when preview and original are the same bytes (tiny photos):
  /// the sender sends one blob and the receiver climbs both rungs at once.
  bool get singleBlob => previewId == photoId;

  String encode() => jsonEncode({
        't': _tag,
        'v': 1,
        'pid': photoId,
        'sha': sha256Hex,
        'pvid': previewId,
        'sz': sizeBytes,
        'pvsz': previewBytes,
        'w': width,
        'h': height,
        'ct': contentType,
        'th': base64Encode(thumbHash),
      });

  static PhotoAnnouncement? tryDecode(String text) {
    if (!text.contains('"$_tag"')) return null;
    try {
      final m = jsonDecode(text);
      if (m is! Map<String, dynamic>) return null;
      if (m['t'] != _tag || m['v'] != 1) return null;
      final pid = m['pid'], sha = m['sha'], pvid = m['pvid'];
      if (pid is! String || pid.length != 32) return null;
      if (sha is! String || sha.length != 64) return null;
      if (pvid is! String || pvid.length != 32) return null;
      final sz = m['sz'], pvsz = m['pvsz'], w = m['w'], h = m['h'];
      if (sz is! int || sz <= 0) return null;
      if (pvsz is! int || pvsz <= 0) return null;
      if (w is! int || h is! int) return null;
      final ct = m['ct'], th = m['th'];
      if (ct is! String || th is! String) return null;
      return PhotoAnnouncement(
        photoId: pid,
        sha256Hex: sha,
        previewId: pvid,
        sizeBytes: sz,
        previewBytes: pvsz,
        width: w,
        height: h,
        contentType: ct,
        thumbHash: base64Decode(th),
      );
    } catch (_) {
      return null; // garbled or foreign JSON is not ours to judge
    }
  }
}

/// Evidence of one delivery, measured — never assumed.
class StagedPhotoSendResult {
  final PhotoAnnouncement announcement;
  final Duration announceElapsed;
  final Duration previewElapsed;
  final Duration originalElapsed;

  /// Resume/dedup evidence from the lane: units are chunks on the ARQ lane
  /// and generations on the fountain lane. resumed == total means the far
  /// side already held every byte — the "re-send is instant" dividend.
  final int resumedUnits;
  final int totalUnits;

  /// Fountain-only wire-overhead evidence (0 on the ARQ lane).
  final int sentSymbols;
  final int totalSourceSymbols;

  bool get deduplicated => totalUnits > 0 && resumedUnits == totalUnits;

  StagedPhotoSendResult({
    required this.announcement,
    required this.announceElapsed,
    required this.previewElapsed,
    required this.originalElapsed,
    required this.resumedUnits,
    required this.totalUnits,
    required this.sentSymbols,
    required this.totalSourceSymbols,
  });
}

/// Sends staged photos: announcement on the reliable text path (injected),
/// then preview, then original on the binary lane. One sender instance per
/// lane port; reuse across photos is supported (and is what makes repeat
/// sends of the same photo complete from the receiver's cache).
class StagedPhotoSender {
  final Future<void> Function(String text) announce;
  final StagedPhotoLane lane;
  final BinaryStreamSender? _arq;
  final FountainStreamSender? _fountain;

  /// Stage transitions for a sender-side progress UI. Called with the stage
  /// ABOUT to start; [PhotoStage.originalVerified] fires on completion.
  void Function(String photoId, PhotoStage stage)? onStage;

  StagedPhotoSender.arq(
    DataChannelPort lanePort, {
    required this.announce,
    required Duration retransmitAfter,
    int chunkBytes = 16 * 1024,
    int? Function()? transportBufferedBytes,
    int Function()? sendBudgetBytesPerSec,
  })  : lane = StagedPhotoLane.arq,
        _fountain = null,
        _arq = BinaryStreamSender(
          lanePort,
          retransmitAfter: retransmitAfter,
          chunkBytes: chunkBytes,
          transportBufferedBytes: transportBufferedBytes,
          sendBudgetBytesPerSec: sendBudgetBytesPerSec,
        );

  StagedPhotoSender.fountain(
    DataChannelPort lanePort, {
    required this.announce,
    int symbolBytes = 1024,
    int floorBytesPerSec = 32 * 1024,
    Duration staleAfter = const Duration(seconds: 45),
    int? Function()? transportBufferedBytes,
  })  : lane = StagedPhotoLane.fountain,
        _arq = null,
        _fountain = FountainStreamSender(
          lanePort,
          symbolBytes: symbolBytes,
          floorBytesPerSec: floorBytesPerSec,
          staleAfter: staleAfter,
          transportBufferedBytes: transportBufferedBytes,
        );

  /// One-line live evidence for a slow or dying delivery.
  String diag() => _arq?.diag() ?? 'fountain lane';

  /// ARQ-lane cumulative acked-chunk counter (0 on the fountain lane) —
  /// dedup evidence: a re-send answered from held bytes leaves it flat.
  int get arqAckedChunks => _arq?.ackedChunks ?? 0;

  Future<StagedPhotoSendResult> deliver(StagedPhotoArtifacts a) async {
    final ann = PhotoAnnouncement.fromArtifacts(a);
    final sw = Stopwatch()..start();

    onStage?.call(ann.photoId, PhotoStage.announced);
    await announce(ann.encode());
    final tAnn = sw.elapsed;

    // Contract: the preview COMPLETES before the original's first frame,
    // so a live receiver climbs the ladder in order. Tiny photos whose
    // preview equals the original send one blob.
    var tPrev = Duration.zero;
    if (!ann.singleBlob) {
      onStage?.call(ann.photoId, PhotoStage.previewReady);
      await _sendBlob(a.preview);
      tPrev = sw.elapsed - tAnn;
    }

    onStage?.call(ann.photoId, PhotoStage.originalVerified);
    final res = await _sendBlob(a.original);
    final tOrig = sw.elapsed - tAnn - tPrev;

    return StagedPhotoSendResult(
      announcement: ann,
      announceElapsed: tAnn,
      previewElapsed: tPrev,
      originalElapsed: tOrig,
      resumedUnits: res.$1,
      totalUnits: res.$2,
      sentSymbols: res.$3,
      totalSourceSymbols: res.$4,
    );
  }

  Future<(int, int, int, int)> _sendBlob(Uint8List bytes) async {
    final arq = _arq;
    if (arq != null) {
      final r = await arq.send(bytes);
      return (r.resumedChunks, r.totalChunks, 0, 0);
    }
    final r = await _fountain!.send(bytes);
    return (
      r.resumedGenerations,
      r.totalGenerations,
      r.sentSymbols,
      r.totalSourceSymbols,
    );
  }
}

/// One received photo's ladder state, kept for the UI to rebuild from.
class StagedPhotoState {
  final PhotoAnnouncement announcement;
  Uint8List? preview;
  Uint8List? original;
  PhotoStage stage = PhotoStage.announced;

  /// True only after the assembled original matched the announcement's
  /// FULL sha256 — the badge the bubble shows.
  bool sha256Verified = false;

  StagedPhotoState(this.announcement);
}

/// One ladder event for the UI: which photo moved to which rung.
class StagedPhotoUpdate {
  final String photoId;
  final PhotoStage stage;
  final StagedPhotoState state;

  /// True when this rung was answered from bytes already held (a repeat
  /// announcement of a completed photo) — rendered instantly.
  final bool deduplicated;

  StagedPhotoUpdate(this.photoId, this.stage, this.state,
      {this.deduplicated = false});
}

/// Receives staged photos: feed announcement texts via [offerText]; binary
/// rungs are claimed from the lane by content address as they complete.
class StagedPhotoReceiver {
  final StagedPhotoLane lane;
  BinaryStreamReceiver? _arq;
  FountainStreamReceiver? _fountain;
  StreamSubscription<BinaryReceived>? _arqSub;

  final _updates = StreamController<StagedPhotoUpdate>.broadcast();
  final _states = <String, StagedPhotoState>{};

  /// Blobs can beat their announcement under reordering; a small bounded
  /// stash holds them until the announcement claims them by id.
  static const int _maxOrphans = 8;
  final _orphans = <String, Uint8List>{};

  StagedPhotoReceiver.arq(DataChannelPort lanePort)
      : lane = StagedPhotoLane.arq {
    _arq = BinaryStreamReceiver(lanePort);
    _arqSub = _arq!.completed.listen((r) {
      if (r.sha256Ok) _onBlob(r.bytes);
    });
  }

  StagedPhotoReceiver.fountain(
    DataChannelPort lanePort, {
    Duration expireAfter = const Duration(seconds: 90),
  }) : lane = StagedPhotoLane.fountain {
    _fountain = FountainStreamReceiver(
      lanePort,
      expireAfter: expireAfter,
      onCompleted: _onBlob,
    );
  }

  Stream<StagedPhotoUpdate> get updates => _updates.stream;

  /// Ladder states by photoId, for UIs that rebuild from state.
  Map<String, StagedPhotoState> get photos => Map.unmodifiable(_states);

  /// Live evidence for a silent ladder: blobs held without an announcement
  /// to claim them. A non-zero count with a finished sender means the
  /// announcement leg, not the lane, is the dead layer.
  int get orphanCount => _orphans.length;

  /// Returns true when [text] was a photo announcement (consumed), false
  /// when it is ordinary chat text the caller should handle itself.
  bool offerText(String text) {
    final ann = PhotoAnnouncement.tryDecode(text);
    if (ann == null) return false;

    final existing = _states[ann.photoId];
    if (existing != null) {
      // Repeat announcement — the dedup dividend: whatever rungs we hold
      // render instantly on the far side of a "re-send".
      _emit(StagedPhotoUpdate(ann.photoId, existing.stage, existing,
          deduplicated: existing.stage != PhotoStage.announced));
      return true;
    }

    final st = StagedPhotoState(ann);
    _states[ann.photoId] = st;
    _emit(StagedPhotoUpdate(ann.photoId, PhotoStage.announced, st));

    // Claim any blob that arrived ahead of its announcement.
    final orphanPreview = _orphans.remove(ann.previewId);
    if (orphanPreview != null && !ann.singleBlob) {
      _acceptPreview(st, orphanPreview);
    }
    final orphanOriginal = _orphans.remove(ann.photoId);
    if (orphanOriginal != null) {
      _acceptOriginal(st, orphanOriginal);
    }
    return true;
  }

  void _onBlob(Uint8List bytes) {
    final id = _hex(_id16(bytes));
    for (final st in _states.values) {
      if (id == st.announcement.photoId) {
        _acceptOriginal(st, bytes);
        return;
      }
      if (id == st.announcement.previewId &&
          !st.announcement.singleBlob) {
        _acceptPreview(st, bytes);
        return;
      }
    }
    _orphans[id] = bytes;
    while (_orphans.length > _maxOrphans) {
      _orphans.remove(_orphans.keys.first);
    }
  }

  void _acceptPreview(StagedPhotoState st, Uint8List bytes) {
    if (st.stage != PhotoStage.announced) return; // never downgrade
    st.preview = bytes;
    st.stage = PhotoStage.previewReady;
    _emit(StagedPhotoUpdate(st.announcement.photoId, st.stage, st));
  }

  void _acceptOriginal(StagedPhotoState st, Uint8List bytes) {
    if (st.stage == PhotoStage.originalVerified) return;
    // The lane already proved sha-prefix16 + length; the announcement's
    // FULL hash closes the last 16 bytes of doubt end-to-end.
    final full = _hex(sha256.convert(bytes).bytes);
    if (full != st.announcement.sha256Hex) return; // impostor — keep waiting
    st.original = bytes;
    if (st.announcement.singleBlob) st.preview = bytes;
    st.sha256Verified = true;
    st.stage = PhotoStage.originalVerified;
    _emit(StagedPhotoUpdate(st.announcement.photoId, st.stage, st));
  }

  void _emit(StagedPhotoUpdate u) {
    if (!_updates.isClosed) _updates.add(u);
  }

  Future<void> close() async {
    await _arqSub?.cancel();
    await _arq?.close();
    await _fountain?.dispose();
    await _updates.close();
  }
}
