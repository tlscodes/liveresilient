/// Which delivery path a payload takes, decided once, in one place.
///
/// The project has two working paths and they fail in opposite directions:
///
/// - the ACKNOWLEDGED path (`ReliableMessenger` + `AttachmentChunker`):
///   ordered chunks, acks, ~2 s retries. Correct and cheap for small text,
///   where an ack costs less than the redundancy that would replace it.
///   Above roughly 10% loss its retry loop degrades badly: every lost chunk
///   costs a round trip, and round trips are what a bad link does not have.
/// - the CLIFF-FREE path (`CliffFreeMediaSender` + `CliffFreeInbox`): rateless
///   symbols, no acks, no retransmission, quality that grows with whatever
///   arrives. It carries a redundancy cost that is pure waste on a clean link
///   and pure survival on a bad one.
///
/// Neither is "better". The router encodes when each is right, so the choice
/// stops being made implicitly by whichever call site a feature grew out of.
library;

import 'resilient_media_transport.dart' show MediaType;

enum MediaPath {
  /// Ordered chunks with acknowledgements and retries.
  acknowledged,

  /// Rateless layered symbols, no feedback.
  cliffFree,
}

class MediaRouteDecision {
  const MediaRouteDecision(this.path, this.reason);

  final MediaPath path;

  /// Why, in words, so a log line explains itself.
  final String reason;

  bool get isCliffFree => path == MediaPath.cliffFree;
}

class MediaSendRouter {
  const MediaSendRouter({
    this.smallTextCeilingBytes = 2048,
    this.lossThreshold = 0.10,
  });

  /// Text at or below this size stays on the acknowledged path.
  ///
  /// 2 KB is where the arithmetic turns over: a 2 KB message is ~37 symbols at
  /// 55 bytes, so even a modest redundancy factor costs more bytes than the
  /// single ack it would replace, and text has no useful layering — there is no
  /// "coarse version" of a sentence to render early.
  final int smallTextCeilingBytes;

  /// Loss estimate above which even small text moves to the cliff-free path.
  ///
  /// The acknowledged path does not fail gracefully here: it stalls. Below the
  /// threshold acks are cheaper; above it they are a round-trip tax on a link
  /// that cannot pay.
  final double lossThreshold;

  /// [lossEstimate] is the blind channel estimate when one exists; pass 0 when
  /// nothing is known, which keeps small text on the cheap path.
  MediaRouteDecision route({
    required MediaType type,
    required int byteLength,
    double lossEstimate = 0.0,
  }) {
    // A NaN estimate compares FALSE against every threshold, so an unguarded
    // router silently treats "we have no idea" as "the link is clean" — the
    // worst available failure direction, and one that leaves no trace. An
    // infinite estimate then throws from the message formatter below. Neither
    // is a channel state; both are a broken estimator, and the safe reading of
    // a broken estimator is that the link might be bad.
    if (lossEstimate.isNaN || lossEstimate.isInfinite) {
      return const MediaRouteDecision(
        MediaPath.cliffFree,
        'loss estimate is not a number: routing as if the link were bad, '
        'because an unusable estimate is not evidence of a good link',
      );
    }
    if (lossEstimate > lossThreshold) {
      return MediaRouteDecision(
        MediaPath.cliffFree,
        'loss estimate ${(lossEstimate * 100).round()}% exceeds threshold; '
        'acks would cost round trips this link cannot pay',
      );
    }

    switch (type) {
      case MediaType.photo:
      case MediaType.flipbook:
      case MediaType.audioPcm:
        return const MediaRouteDecision(
          MediaPath.cliffFree,
          'media is layerable: the base layer renders before the object is '
          'whole, and a lost symbol costs quality rather than a round trip',
        );
      case MediaType.document:
        if (byteLength <= smallTextCeilingBytes) {
          return MediaRouteDecision(
            MediaPath.acknowledged,
            'text of $byteLength B is below the ${smallTextCeilingBytes} B '
            'ceiling: one ack is cheaper than the redundancy replacing it',
          );
        }
        return MediaRouteDecision(
          MediaPath.cliffFree,
          'document of $byteLength B is large enough that a stalled retry loop '
          'costs more than rateless redundancy',
        );
    }
  }
}
