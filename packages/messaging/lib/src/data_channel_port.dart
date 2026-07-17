/// Bidirectional binary-frame transport — the only thing the messaging layer
/// depends on. A WebRTC DataChannel binding (native) implements this; tests use
/// an in-memory loopback. This mirrors the media_webrtc / media_webrtc_flutter
/// split: pure-Dart logic here, native binding elsewhere.
abstract class DataChannelPort {
  /// Frames received from the remote peer. Broadcast so multiple listeners
  /// (or none) are fine; a frame delivered before anyone listens may be lost,
  /// so subscribe before sending.
  Stream<List<int>> get inbound;

  /// Sends one frame to the remote peer. Completes when handed to the channel
  /// (not when the peer receives it — delivery is confirmed by the ack layer).
  Future<void> send(List<int> frame);

  /// Closes the channel and releases its resources.
  Future<void> close();
}
