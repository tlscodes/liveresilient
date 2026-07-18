import 'dart:convert';

import 'chat_message.dart';

/// A decoded wire frame: either a message or an acknowledgement.
sealed class WireFrame {
  const WireFrame();
}

final class MessageFrame extends WireFrame {
  final ChatMessage message;
  const MessageFrame(this.message);
}

final class AckFrame extends WireFrame {
  final String id;
  const AckFrame(this.id);
}

/// JSON wire codec. Frame shapes (version-gated):
///   message: {v, type:"msg", id, sender, seq, ts, ct, body}
///   ack:     {v, type:"ack", id}
class WireCodec {
  static const int version = 1;

  /// Hard ceiling on an inbound frame's byte length, checked before any
  /// parsing touches the bytes — matches signed_config's fetch-cap
  /// convention (256 KiB) so a hostile/oversized peer frame is rejected for
  /// the cost of a length check, never a full JSON parse.
  static const int maxFrameBytes = 262144;

  static List<int> encodeMessage(ChatMessage m) => utf8.encode(
    jsonEncode({
      'v': version,
      'type': 'msg',
      'id': m.id,
      'sender': m.senderId,
      'seq': m.seq,
      'ts': m.sentAtMs,
      'ct': m.contentType,
      'body': m.text,
    }),
  );

  static List<int> encodeAck(String id) =>
      utf8.encode(jsonEncode({'v': version, 'type': 'ack', 'id': id}));

  /// Decodes a frame, or returns null if the bytes are not a recognizable
  /// frame of this version. NEVER throws on malformed/hostile peer input — a
  /// garbled frame is simply ignored by the caller.
  static WireFrame? tryDecode(List<int> bytes) {
    if (bytes.length > maxFrameBytes) return null;
    try {
      final obj = jsonDecode(utf8.decode(bytes));
      if (obj is! Map || obj['v'] != version) return null;
      final ct = obj['ct'];
      if (ct != null && (ct is! String || ct.length > 255)) return null;
      switch (obj['type']) {
        case 'ack':
          final id = obj['id'];
          return id is String ? AckFrame(id) : null;
        case 'msg':
          final id = obj['id'];
          final sender = obj['sender'];
          final seq = obj['seq'];
          final ts = obj['ts'];
          final body = obj['body'];
          if (id is! String ||
              sender is! String ||
              seq is! int ||
              ts is! int ||
              body is! String) {
            return null;
          }
          return MessageFrame(
            ChatMessage(
              id: id,
              senderId: sender,
              seq: seq,
              sentAtMs: ts,
              contentType: ct is String ? ct : 'text/plain',
              text: body,
            ),
          );
        default:
          return null;
      }
    } catch (_) {
      return null;
    }
  }
}
