/// Video notes: one content-addressed blob on the binary stream lane, plus a
/// small announcement on the chat messenger.
///
/// The announcement (JSON, carried as ordinary reliable chat text) tells the
/// receiver what is coming — size, full sha256, content type, duration — so a
/// bubble can appear before a byte lands and the completed blob can be
/// judged: a note is `verified` only when the lane's own DONE check passed
/// AND the assembled bytes hash to the announced sha256. Anything else is
/// `failed`, never silently shown as if it were the sender's clip.
///
/// Content addressing does the pairing: the lane's transferId is
/// sha256(bytes)[0:16] ([BinaryStreamSender]), and the announcement carries
/// the same 16 bytes as `videoId`, so an announcement and a blob meet by id
/// in either arrival order.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'binary_stream_transfer.dart';
import 'data_channel_port.dart';

/// Hex of the full sha256 of [bytes] — the verified badge's value, exposed
/// so callers can record what they sent without a second hashing library.
String contentSha256Hex(List<int> bytes) => _hex(sha256.convert(bytes).bytes);

/// Hex of sha256(bytes)[0:16] — the lane transferId a blob will carry.
String contentAddressHex(List<int> bytes) =>
    _hex(sha256.convert(bytes).bytes.sublist(0, 16));

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// What the sender says about a note before the bytes travel.
class VideoNoteAnnouncement {
  /// hex sha256(bytes)[0:16] — equals the lane transferId of the blob.
  final String videoId;

  /// FULL sha256 of the clip — the verified badge.
  final String sha256Hex;
  final int byteLength;
  final String contentType;
  final int durationMs;

  const VideoNoteAnnouncement({
    required this.videoId,
    required this.sha256Hex,
    required this.byteLength,
    required this.contentType,
    required this.durationMs,
  });

  factory VideoNoteAnnouncement.forBytes(
    List<int> bytes, {
    required String contentType,
    required int durationMs,
  }) {
    final digest = sha256.convert(bytes).bytes;
    return VideoNoteAnnouncement(
      videoId: _hex(digest.sublist(0, 16)),
      sha256Hex: _hex(digest),
      byteLength: bytes.length,
      contentType: contentType,
      durationMs: durationMs,
    );
  }

  static const String _magic = 'vck-video-note';

  String encode() => jsonEncode(<String, Object>{
    'v': _magic,
    'id': videoId,
    'sha': sha256Hex,
    'bytes': byteLength,
    'type': contentType,
    'ms': durationMs,
  });

  /// Decodes an announcement, or null when [text] is anything else (plain
  /// chat, another lane's announcement, malformed JSON).
  static VideoNoteAnnouncement? tryDecode(String text) {
    if (!text.startsWith('{') || !text.contains(_magic)) return null;
    try {
      final decoded = jsonDecode(text);
      if (decoded is! Map<String, Object?>) return null;
      if (decoded['v'] != _magic) return null;
      final id = decoded['id'];
      final sha = decoded['sha'];
      final bytes = decoded['bytes'];
      final type = decoded['type'];
      final ms = decoded['ms'];
      if (id is! String ||
          id.length != 32 ||
          sha is! String ||
          sha.length != 64 ||
          bytes is! int ||
          bytes < 0 ||
          type is! String ||
          ms is! int ||
          ms < 0) {
        return null;
      }
      return VideoNoteAnnouncement(
        videoId: id,
        sha256Hex: sha,
        byteLength: bytes,
        contentType: type,
        durationMs: ms,
      );
    } on FormatException {
      return null;
    }
  }
}

enum VideoNoteStage { announced, verified, failed }

/// One received note's state, kept for the UI to rebuild from.
class VideoNoteState {
  final VideoNoteAnnouncement announcement;
  Uint8List? bytes;
  VideoNoteStage stage = VideoNoteStage.announced;

  VideoNoteState(this.announcement);
}

class VideoNoteUpdate {
  final String videoId;
  final VideoNoteStage stage;
  final VideoNoteState state;

  const VideoNoteUpdate(this.videoId, this.stage, this.state);
}

/// Sends video notes: announcement on the messenger via [announce], bytes
/// on the binary lane. [deliver] completes when the far side verified the
/// whole blob (the lane's DONE), so its return is a delivery receipt.
class VideoNoteSender {
  VideoNoteSender(
    DataChannelPort lanePort, {
    required Future<void> Function(String text) announce,
    required Duration retransmitAfter,
    int chunkBytes = 8 * 1024,
    int? Function()? transportBufferedBytes,
    int Function()? sendBudgetBytesPerSec,
  }) : _announce = announce,
       _sender = BinaryStreamSender(
         lanePort,
         retransmitAfter: retransmitAfter,
         chunkBytes: chunkBytes,
         transportBufferedBytes: transportBufferedBytes,
         sendBudgetBytesPerSec: sendBudgetBytesPerSec,
       );

  final Future<void> Function(String text) _announce;
  final BinaryStreamSender _sender;

  /// Freezes/resumes the lane (call-recovery episodes hand the link to
  /// signaling; content addressing makes the freeze free).
  void pause() => _sender.pause();
  void resume() => _sender.resume();

  Future<VideoNoteAnnouncement> deliver(
    List<int> bytes, {
    required String contentType,
    required int durationMs,
  }) async {
    final announcement = VideoNoteAnnouncement.forBytes(
      bytes,
      contentType: contentType,
      durationMs: durationMs,
    );
    await _announce(announcement.encode());
    await _sender.send(bytes);
    return announcement;
  }
}

/// Receives video notes: feed messenger texts through [offerText] (true when
/// consumed); blobs arrive off the lane by themselves. [updates] fires once
/// per rung: announced, then verified or failed.
class VideoNoteReceiver {
  VideoNoteReceiver(DataChannelPort lanePort)
    : _receiver = BinaryStreamReceiver(lanePort) {
    _sub = _receiver.completed.listen(_onCompleted);
  }

  final BinaryStreamReceiver _receiver;
  late final StreamSubscription<BinaryReceived> _sub;
  final _updates = StreamController<VideoNoteUpdate>.broadcast();

  /// Blobs that landed before their announcement, by videoId.
  final Map<String, BinaryReceived> _earlyBlobs = <String, BinaryReceived>{};
  static const int _maxEarlyBlobs = 8;

  /// Every note announced so far, by videoId.
  final Map<String, VideoNoteState> notes = <String, VideoNoteState>{};

  Stream<VideoNoteUpdate> get updates => _updates.stream;

  bool offerText(String text) {
    final announcement = VideoNoteAnnouncement.tryDecode(text);
    if (announcement == null) return false;
    final existing = notes[announcement.videoId];
    if (existing != null) {
      // A repeat announcement (retry, or the same clip sent twice) is
      // answered from what we hold: re-emit the current rung.
      _emit(existing.announcement.videoId, existing.stage, existing);
      return true;
    }
    final state = VideoNoteState(announcement);
    notes[announcement.videoId] = state;
    _emit(announcement.videoId, VideoNoteStage.announced, state);
    final early = _earlyBlobs.remove(announcement.videoId);
    if (early != null) _judge(state, early);
    return true;
  }

  void _onCompleted(BinaryReceived received) {
    final id = _hex(received.transferId);
    final state = notes[id];
    if (state == null) {
      if (_earlyBlobs.length >= _maxEarlyBlobs) {
        _earlyBlobs.remove(_earlyBlobs.keys.first);
      }
      _earlyBlobs[id] = received;
      return;
    }
    _judge(state, received);
  }

  void _judge(VideoNoteState state, BinaryReceived received) {
    if (state.stage == VideoNoteStage.verified) return;
    final full = _hex(sha256.convert(received.bytes).bytes);
    final ok =
        received.sha256Ok &&
        full == state.announcement.sha256Hex &&
        received.bytes.length == state.announcement.byteLength;
    if (ok) {
      state
        ..bytes = received.bytes
        ..stage = VideoNoteStage.verified;
    } else {
      state.stage = VideoNoteStage.failed;
    }
    _emit(state.announcement.videoId, state.stage, state);
  }

  void _emit(String id, VideoNoteStage stage, VideoNoteState state) {
    if (!_updates.isClosed) _updates.add(VideoNoteUpdate(id, stage, state));
  }

  Future<void> close() async {
    await _sub.cancel();
    await _receiver.close();
    await _updates.close();
  }
}
