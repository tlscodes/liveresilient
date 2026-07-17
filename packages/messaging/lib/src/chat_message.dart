/// The kind of payload a [ChatMessage] carries. Only text today; the enum
/// leaves room for file/media descriptors without a wire-format break.
enum MessageKind { text }

/// An application chat message — the unit the UI sends and receives.
///
/// [id] is globally unique as `"<senderId>-<seq>"`, which lets the receiver
/// de-duplicate retransmissions and the sender match acknowledgements.
class ChatMessage {
  final String id;
  final String senderId;

  /// Per-sender monotonic sequence number (also encodes ordering).
  final int seq;

  /// Send time in epoch milliseconds (sender's clock).
  final int sentAtMs;

  final MessageKind kind;
  final String contentType;
  final String text;

  const ChatMessage({
    required this.id,
    required this.senderId,
    required this.seq,
    required this.sentAtMs,
    this.kind = MessageKind.text,
    this.contentType = 'text/plain',
    required this.text,
  });

  @override
  String toString() => 'ChatMessage($id, from $senderId, "$text")';
}
