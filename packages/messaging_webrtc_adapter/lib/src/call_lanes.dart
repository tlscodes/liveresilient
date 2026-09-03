/// The negotiated data-channel lanes a call carries, one place for both peers.
///
/// Negotiated mode (RFC 8831 §6) needs BOTH sides to create the same stream
/// id with the same ordering; there is no in-band announcement. So the lane
/// table is a shared constant, not a per-caller choice, and every session —
/// the app's, the test rig's, the phone-side peer's — pre-opens exactly this
/// list at media start so the first offer already carries the application
/// section (a lane opened after an audio-only offer has no SCTP transport
/// until a full renegotiation round trip).
///
/// Ids are stable API: changing one breaks interop with every deployed peer.
library;

import 'package:media_webrtc/media_webrtc.dart';

abstract final class CallLanes {
  /// Survival-mode store-and-forward and call-memory replay: the messaging
  /// layer's original lane (the `DataChannelConfig` default).
  static const DataChannelConfig messaging = DataChannelConfig();

  /// Chat text, delivery acks and chunked attachments (voice notes, files):
  /// ordered and fully reliable — the reliable messenger's own retry sits on
  /// top, so ordering here only keeps a conversation readable in send order.
  static const DataChannelConfig chat = DataChannelConfig(
    label: 'vck-chat',
    negotiatedId: 2,
  );

  /// Staged photo ladder (thumbhash → preview → sha-verified original):
  /// unordered, the lane's own ARQ/fountain layer sequences the stream.
  static const DataChannelConfig photo = DataChannelConfig(
    label: 'vck-photo',
    negotiatedId: 9,
    ordered: false,
  );

  /// Video notes and clips over the binary/fountain stream lane: unordered
  /// for the same reason, sized by the lane's own flow control.
  static const DataChannelConfig video = DataChannelConfig(
    label: 'vck-video',
    negotiatedId: 1,
    ordered: false,
  );

  /// Every lane, in the order sessions pre-open them.
  static const List<DataChannelConfig> all = <DataChannelConfig>[
    messaging,
    chat,
    photo,
    video,
  ];
}
