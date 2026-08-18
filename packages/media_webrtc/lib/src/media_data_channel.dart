/// Application data channel over the peer connection.
///
/// WebRTC data channels run SCTP over the same DTLS transport as the media
/// (RFC 8831), so frames sent here inherit exactly the call's encryption —
/// no additional crypto and no separate connection. This surface exists so
/// the messaging layer (reliable text + chunked attachments) can ride the
/// live call instead of a separate transport.
///
/// The kit uses NEGOTIATED channels only (RFC 8832 negotiated mode): both
/// peers construct the channel locally with the same pre-agreed id, so no
/// in-band open handshake ordering matters and neither side needs an
/// "onDataChannel" callback. That keeps this surface minimal and the
/// behavior deterministic on both ends.
library;

import 'dart:async';

/// Lifecycle of a data channel, mirroring `RTCDataChannelState` minus the
/// platform-specific spellings.
enum MediaDataChannelState { connecting, open, closing, closed }

/// Static configuration for a negotiated data channel. Both peers must use
/// identical values — that is what "negotiated" means on the wire.
class DataChannelConfig {
  /// Human-readable label; carried in SCTP metadata, not used for routing.
  final String label;

  /// Pre-agreed channel id (SCTP stream id). Both sides must match.
  final int negotiatedId;

  /// Ordered delivery. The messaging layer's own ack/retry tolerates
  /// reordering, but ordered:true is the standard default and costs nothing
  /// at chat message rates.
  final bool ordered;

  /// SCTP partial-reliability retransmit cap (RFC 3758 limited-retransmission
  /// policy). null (default) = fully reliable, today's behavior everywhere.
  /// 0 = the transport never retransmits a frame — the fountain video lane's
  /// hard precondition: on a reliable channel SCTP retransmits underneath and
  /// rebuilds the exact loss-collapse that lane exists to escape (see
  /// messaging/src/fountain_stream_transfer.dart header). Reliability is a
  /// per-side local send policy, not SDP: negotiated channels exchange no
  /// DCEP OPEN, so both peers must pass the same value here for the channel
  /// to be unreliable in both directions.
  final int? maxRetransmits;

  const DataChannelConfig({
    this.label = 'vck-messaging',
    this.negotiatedId = 0,
    this.ordered = true,
    this.maxRetransmits,
  });

  /// Validates field ranges; called by ports before touching the platform.
  void validate() {
    if (label.isEmpty || label.length > 128) {
      throw ArgumentError.value(label, 'label', 'must be 1-128 characters');
    }
    // SCTP stream ids are 0..65534 (65535 is reserved).
    if (negotiatedId < 0 || negotiatedId > 65534) {
      throw ArgumentError.value(
        negotiatedId,
        'negotiatedId',
        'must be 0-65534',
      );
    }
    final cap = maxRetransmits;
    if (cap != null && (cap < 0 || cap > 65535)) {
      throw ArgumentError.value(
        cap,
        'maxRetransmits',
        'must be null (reliable) or 0-65535',
      );
    }
  }
}

/// A live (or opening) data channel produced by a peer-connection port.
///
/// Contract notes for implementers:
/// - [inbound] and [state] are broadcast streams; a frame delivered before
///   anyone listens may be lost, so consumers subscribe before signaling
///   readiness (same rule as the messaging layer's DataChannelPort).
/// - [send] completes when the frame is handed to the platform channel, not
///   when the peer receives it — delivery confirmation belongs to the
///   messaging layer's ack protocol.
/// - [close] is idempotent.
abstract interface class MediaDataChannel {
  String get label;
  Stream<MediaDataChannelState> get state;
  Stream<List<int>> get inbound;
  Future<void> send(List<int> frame);
  Future<void> close();

  /// The channel's state right now, [MediaDataChannelState.connecting] until
  /// an event says otherwise, [MediaDataChannelState.closed] after [close].
  ///
  /// [state] is a broadcast stream: an open event delivered while nobody is
  /// subscribed (e.g. during an await between channel creation and port
  /// construction) is gone, and a negotiated channel on an already-established
  /// SCTP association opens immediately (measured 2026-08-11, staged-photo
  /// lane: acked=0 minRtt=-1 inside a healthy call). Consumers gating sends on
  /// openness must subscribe to [state] and then seed from this getter; the
  /// stream alone is not sufficient.
  MediaDataChannelState get currentState;

  /// Bytes queued in the transport's send buffer, or null where the
  /// platform does not report it. THE flow-control signal (standard
  /// RTCDataChannel.bufferedAmount): a bulk sender that ignores it was
  /// measured (2026-08-08, T2 bandwidth/latency video rows) pushing its
  /// tail chunks into a full buffer whose silent drop looked exactly like
  /// a dead receiver — flatlined acks, open channel, live call.
  int? get bufferedAmount;
}
