/// In-memory [BundleCarrierPort] pair for tests: joins two endpoints as if
/// they were in radio range (or docked, or briefly uplinked) with no real
/// transport underneath. Not a platform adapter — production carriers
/// (BLE, Wi-Fi Direct, a scheduled uplink check) implement the same port
/// against real hardware.
library;

import 'dart:async';

import 'bundle_carrier_port.dart';
import 'dtn_bundle_queue.dart';

/// A contact whose [isOpen] can be flipped by the test/simulation driving
/// it, to model a mid-transfer interruption.
class SimulatedContact implements BundleContact {
  SimulatedContact(this.peerId);

  @override
  final String peerId;

  @override
  bool isOpen = true;

  /// Ends the contact (peer moved out of range / uplink dropped).
  void close() => isOpen = false;
}

/// Joins two named endpoints in memory. Calling [openContact] fires a
/// [SimulatedContact] on both ports' [contacts] streams; the returned
/// [SimulatedContact] is shared, so closing it via [SimulatedContact.close]
/// is what a test uses to simulate an interruption mid-exchange.
class SimulatedCarrierLink {
  SimulatedCarrierLink({required this.nodeAId, required this.nodeBId});

  final String nodeAId;
  final String nodeBId;

  final StreamController<BundleContact> _aContacts =
      StreamController<BundleContact>.broadcast();
  final StreamController<BundleContact> _bContacts =
      StreamController<BundleContact>.broadcast();

  /// Port as seen from node A; its contacts report node B as the peer.
  BundleCarrierPort get portForA => _SimulatedPort(_aContacts.stream);

  /// Port as seen from node B; its contacts report node A as the peer.
  BundleCarrierPort get portForB => _SimulatedPort(_bContacts.stream);

  /// Opens a contact between A and B and returns the shared handle both
  /// sides observe. The caller runs [BundleExchange] against the queues on
  /// each side using this same nowMs/open-check.
  SimulatedContact openContact({required int nowMs}) {
    final contact = SimulatedContact('$nodeAId<->$nodeBId@$nowMs');
    _aContacts.add(contact);
    _bContacts.add(contact);
    return contact;
  }

  Future<void> dispose() async {
    await _aContacts.close();
    await _bContacts.close();
  }
}

class _SimulatedPort implements BundleCarrierPort {
  _SimulatedPort(this.contacts);

  @override
  final Stream<BundleContact> contacts;
}

/// Convenience helper for tests: runs one contact's exchange in both
/// directions (A offers to B, then B offers to A) using the same
/// [BundleExchange] policy and contact-open check, so a single call models
/// a symmetric peer-to-peer meeting. Returns both directions' reports.
class SimulatedBidirectionalExchange {
  const SimulatedBidirectionalExchange(this.exchange);

  final BundleExchange exchange;

  Future<(BundleExchangeReport aToB, BundleExchangeReport bToA)> run({
    required DtnBundleQueue queueA,
    required DtnBundleQueue queueB,
    required int nowMs,
    RetainPolicy retain = RetainPolicy.handOffAndForget,
    bool Function() isContactOpen = _defaultOpen,
  }) async {
    final aToB = await exchange.run(
      sender: queueA,
      receiver: queueB,
      nowMs: nowMs,
      retain: retain,
      isContactOpen: isContactOpen,
    );
    final bToA = await exchange.run(
      sender: queueB,
      receiver: queueA,
      nowMs: nowMs,
      retain: retain,
      isContactOpen: isContactOpen,
    );
    return (aToB, bToA);
  }
}

bool _defaultOpen() => true;
