/// Intermittent-contact bundle exchange for delay-tolerant delivery.
///
/// A "contact" is any window where two nodes can exchange bundles: two
/// phones near each other, a vehicle-mounted relay that shuttles between
/// distant towns and briefly docks at each, or a hub that periodically
/// gains a backhaul uplink. This abstraction is named by that behavior
/// (contact, carrier) rather than by any specific radio, so the same code
/// covers all three. [BundleCarrierPort] is the seam a platform layer
/// implements (Bluetooth/Wi-Fi Direct scan-and-connect, a scheduled uplink
/// check, a USB dock event, ...); [BundleExchange] is the pure-Dart policy
/// that runs once a contact is established between two [DtnBundleQueue]s.
library;

import 'device_link_adapter.dart' show DeviceLinkConsent;
import 'dtn_bundle_queue.dart';

/// One open exchange window between this node and a peer. Implementations
/// report contact lifecycle; they never see or interpret bundle payloads.
abstract interface class BundleCarrierPort {
  /// Fires when a peer comes within exchange range (by whatever means this
  /// port uses) and stays fired for as long as the contact lasts.
  Stream<BundleContact> get contacts;
}

/// A live contact with a peer, identified by an opaque carrier-assigned id.
/// [isOpen] flips to false when the contact is interrupted (peer moved out
/// of range, uplink dropped) so callers can stop attempting transfer.
abstract interface class BundleContact {
  String get peerId;
  bool get isOpen;
}

/// Whether a bundle handed off during a contact is also kept locally.
enum RetainPolicy {
  /// Hand off and forget: the sender drops the bundle once transferred
  /// (single-copy forwarding).
  handOffAndForget,

  /// Carry and keep: the sender retains its copy after transfer, so the
  /// same bundle can still reach a different peer later (redundancy).
  carryAndKeep,
}

/// Summary of one completed (or interrupted) contact exchange.
class BundleExchangeReport {
  BundleExchangeReport({
    required this.transferred,
    required this.duplicates,
    required this.quotaSkipped,
    required this.interrupted,
    this.consentDenied = false,
  });

  /// True when the contact's [DeviceLinkConsent] was not granted: nothing
  /// was offered, both queues are untouched.
  final bool consentDenied;

  /// Bundle ids successfully handed to the receiver (newly stored there).
  final List<String> transferred;

  /// Bundle ids the receiver already held (deduped, not re-sent).
  final List<String> duplicates;

  /// Bundle ids never attempted this contact: quota ran out or the contact
  /// closed before they were reached.
  final List<String> quotaSkipped;

  /// True when the contact closed before every eligible bundle was offered.
  final bool interrupted;
}

/// Runs one contact between a sending and a receiving [DtnBundleQueue].
///
/// Built entirely on [DtnBundleQueue]'s existing public API
/// (`pendingInDeliveryOrder`, `offer`, `flush`) — the queue itself is never
/// modified. De-dup, expiry, and capacity-shedding on the receiving side
/// are exactly the queue's own `offer()` rules; this class adds only the
/// per-contact transfer quota and the retain-vs-forget policy on top.
///
/// Ordering is priority-then-oldest (`pendingInDeliveryOrder`'s own
/// order), so quota exhaustion or a mid-contact interruption always skips
/// the least-important, newest bundles first, never a more important one
/// ahead of a less important one already sent.
///
/// For [RetainPolicy.handOffAndForget] this uses `sender.flush(...)`,
/// whose existing contract already gives exactly the semantics a real
/// contact needs: it walks bundles in delivery order, removes each one
/// the forwarder reports as handled, and *stops at the first bundle it
/// can't hand off* — leaving every bundle from that point on still queued.
/// That "stop on first failure" behavior is reused here for both quota
/// exhaustion and contact interruption, so an interrupted or
/// quota-limited contact leaves the sender's queue in exactly the state
/// `flush` already guarantees: consistent, nothing half-removed.
class BundleExchange {
  const BundleExchange({this.maxBundlesPerContact, this.maxBytesPerContact});

  /// Upper bound on bundles moved in a single contact; null = unbounded.
  final int? maxBundlesPerContact;

  /// Upper bound on payload bytes moved in a single contact; null =
  /// unbounded.
  final int? maxBytesPerContact;

  Future<BundleExchangeReport> run({
    required DtnBundleQueue sender,
    required DtnBundleQueue receiver,
    required int nowMs,
    RetainPolicy retain = RetainPolicy.handOffAndForget,
    bool Function() isContactOpen = _alwaysOpen,
    DeviceLinkConsent? consent,
  }) async {
    // Consent gate: a carrier contact is a voluntary, owner-opted-in relay.
    // When a [DeviceLinkConsent] is supplied and not granted, no bundle is
    // offered and both queues stay exactly as they were.
    if (consent != null && !consent.granted) {
      return BundleExchangeReport(
        transferred: const [],
        duplicates: const [],
        quotaSkipped: const [],
        interrupted: false,
        consentDenied: true,
      );
    }
    final transferred = <String>[];
    final duplicates = <String>[];
    final quotaSkipped = <String>[];
    var movedBundles = 0;
    var movedBytes = 0;
    var interrupted = false;

    // Snapshot the eligible set once, up front, in delivery order: both
    // the flush-based (forget) and manual (keep) paths below must skip
    // the *same* bundles for the *same* reason so the report is accurate
    // regardless of retain policy.
    bool wouldFitQuota(DtnBundle bundle) {
      final overBundleQuota =
          maxBundlesPerContact != null &&
          movedBundles + 1 > maxBundlesPerContact!;
      final overByteQuota =
          maxBytesPerContact != null &&
          movedBytes + bundle.sizeBytes > maxBytesPerContact!;
      return !overBundleQuota && !overByteQuota;
    }

    if (retain == RetainPolicy.handOffAndForget) {
      await sender.flush((bundle) async {
        if (!isContactOpen()) {
          interrupted = true;
          return false;
        }
        if (!wouldFitQuota(bundle)) {
          quotaSkipped.add(bundle.id);
          return false; // stop: quota exhausted, rest stay queued too.
        }
        final admission = receiver.offer(bundle, nowMs: nowMs);
        switch (admission) {
          case BundleAdmission.stored:
            transferred.add(bundle.id);
            movedBundles++;
            movedBytes += bundle.sizeBytes;
            return true; // handed off — flush removes it from sender.
          case BundleAdmission.duplicate:
            duplicates.add(bundle.id);
            return true; // receiver already has it — safe to drop here.
          case BundleAdmission.expired:
          case BundleAdmission.rejectedFull:
            quotaSkipped.add(bundle.id);
            return true; // undeliverable either way — drop from sender.
        }
      }, nowMs: nowMs);
    } else {
      for (final bundle in sender.pendingInDeliveryOrder(nowMs)) {
        if (!isContactOpen()) {
          interrupted = true;
          break;
        }
        if (!wouldFitQuota(bundle)) {
          quotaSkipped.add(bundle.id);
          continue; // carrying on: later, lower-priority bundles also
          // skipped this contact, but sender keeps everything either way.
        }
        final admission = receiver.offer(bundle, nowMs: nowMs);
        switch (admission) {
          case BundleAdmission.stored:
            transferred.add(bundle.id);
            movedBundles++;
            movedBytes += bundle.sizeBytes;
          case BundleAdmission.duplicate:
            duplicates.add(bundle.id);
          case BundleAdmission.expired:
          case BundleAdmission.rejectedFull:
            quotaSkipped.add(bundle.id);
        }
      }
    }

    return BundleExchangeReport(
      transferred: transferred,
      duplicates: duplicates,
      quotaSkipped: quotaSkipped,
      interrupted: interrupted,
    );
  }
}

bool _alwaysOpen() => true;
