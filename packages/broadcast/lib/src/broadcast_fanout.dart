/// Publishing one post to several relays, tolerating partial failure.
///
/// A publisher writes to every relay it knows and needs only some of them
/// to accept. That asymmetry is the whole point of replication: losing a
/// relay should cost reach, never the ability to publish.
///
/// The per-relay order matters and is enforced here — every object first,
/// the descriptor last. A relay that fails partway through gets no
/// descriptor at all, so it never advertises a post whose layers it does
/// not hold. A reader would survive that anyway by trying another relay,
/// but a relay that answers with a post it cannot complete wastes the one
/// resource a reader on a bad link has least of.
library;

import 'broadcast_publisher.dart';
import 'broadcast_relay.dart';
import 'http_broadcast_relay.dart';

/// What one relay did with one post.
class RelayPublishOutcome {
  const RelayPublishOutcome._(this.relayName, this.failure);

  const RelayPublishOutcome.stored(String relayName) : this._(relayName, null);

  const RelayPublishOutcome.failed(String relayName, BroadcastPublishFailure f)
    : this._(relayName, f);

  final String relayName;

  /// Null when the relay holds the complete post.
  final BroadcastPublishFailure? failure;

  bool get isStored => failure == null;
}

/// The result of publishing one post across a set of relays.
class FanoutResult {
  FanoutResult(List<RelayPublishOutcome> outcomes)
    : outcomes = List.unmodifiable(outcomes);

  final List<RelayPublishOutcome> outcomes;

  /// Relays that hold the complete post.
  List<String> get storedOn => [
    for (final o in outcomes)
      if (o.isStored) o.relayName,
  ];

  /// Relays that did not take it, with the reason each gave.
  Map<String, BroadcastPublishFailure> get failures => {
    for (final o in outcomes)
      if (!o.isStored) o.relayName: o.failure!,
  };

  int get storedCount => storedOn.length;

  /// Whether any relay took a sequence number that another already held
  /// with different bytes.
  ///
  /// Worth singling out: unlike a relay being down, this says the
  /// publisher's own sequence state disagrees with the world, which no
  /// amount of retrying fixes.
  bool get sawConflict =>
      failures.values.contains(BroadcastPublishFailure.conflict);
}

/// Raised when fewer relays accepted a post than the publisher required.
class BroadcastFanoutFailed implements Exception {
  const BroadcastFanoutFailed(this.result, this.required);

  final FanoutResult result;
  final int required;

  @override
  String toString() =>
      'BroadcastFanoutFailed(stored on ${result.storedCount} of '
      '${result.outcomes.length}, needed $required; ${result.failures})';
}

/// Publishes to every relay it is given.
class BroadcastFanout {
  BroadcastFanout({
    required List<BroadcastRelay> relays,
    this.minimumRelays = 1,
  }) : relays = List.unmodifiable(relays) {
    if (relays.isEmpty) {
      throw ArgumentError.value(relays, 'relays', 'nowhere to publish');
    }
    if (minimumRelays < 1 || minimumRelays > relays.length) {
      throw ArgumentError.value(
        minimumRelays,
        'minimumRelays',
        'must be 1..${relays.length}',
      );
    }
  }

  final List<BroadcastRelay> relays;

  /// How many relays must hold the complete post for [publish] to succeed.
  ///
  /// One by default: a post that reached anywhere is published, and a
  /// reader needs only one working relay to find it. Raise it when a
  /// deployment would rather fail loudly than publish somewhere it
  /// considers too thin.
  final int minimumRelays;

  /// Writes [post] everywhere, in parallel.
  ///
  /// Parallel because the relays are independent and a slow or blocked one
  /// should not delay the others; a publisher on a bad link is usually
  /// waiting on the worst relay, not on bandwidth.
  Future<FanoutResult> publish(BroadcastPost post) async {
    final outcomes = await Future.wait([
      for (final relay in relays) _publishTo(relay, post),
    ]);
    final result = FanoutResult(outcomes);
    if (result.storedCount < minimumRelays) {
      throw BroadcastFanoutFailed(result, minimumRelays);
    }
    return result;
  }

  Future<RelayPublishOutcome> _publishTo(
    BroadcastRelay relay,
    BroadcastPost post,
  ) async {
    try {
      for (final bytes in post.objects.values) {
        await relay.putObject(bytes);
      }
      await relay.putDescriptor(post.address, post.descriptor.encoded);
      return RelayPublishOutcome.stored(relay.name);
    } on BroadcastPublishRejected catch (rejected) {
      return RelayPublishOutcome.failed(relay.name, rejected.failure);
    } on Object {
      // A relay that throws something else is simply unusable. Naming it
      // "refused" rather than letting it escape keeps one broken relay
      // from failing a publish that succeeded elsewhere.
      return RelayPublishOutcome.failed(
        relay.name,
        BroadcastPublishFailure.refused,
      );
    }
  }
}
