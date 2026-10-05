// The mailbox: a name on the relay the letter lanes already use.
//
// The border relay pairs two sides of a named session and holds what one
// side sent until the other asks (its long-poll route). A call uses that
// for live frames under the call's id. A mailbox is the same thing with one
// tenant: the session is the recipient's install id, anyone may put a box
// in as side `a`, and the install itself reads as side `b`. No new server,
// no new route, no new lane — the long-poll lane, used in both directions.
//
// The relay holds a box only while the session is alive (minutes of
// idleness), so a mailbox is a hand-over point, not storage. Delivery is
// made reliable above it: the sender keeps the letter until a receipt
// comes back and puts the box in again until it does.
//
// What the relay can do: drop boxes, and let anyone who knows a public
// install id read (and so remove) that mailbox's boxes. What it cannot do
// is open one, forge one, or learn who wrote it.
import 'dart:typed_data';

import 'package:adaptive_transport/adaptive_transport.dart'
    show HttpLongPollLane;
import 'package:connection_orchestrator/connection_orchestrator.dart'
    show ResilientLaneEndpoints;

/// Where boxes are handed over.
abstract class MailboxDoor {
  /// Puts [box] in the mailbox named [install]. True when the relay took
  /// it; false when the door was down.
  Future<bool> deposit(String install, Uint8List box);

  /// Takes whatever is waiting in the mailbox named [install], waiting up
  /// to [wait] for the first box. Empty when nothing came; null when the
  /// door was down.
  Future<Uint8List?> take(String install, {Duration wait = Duration.zero});

  Future<void> dispose();
}

/// The long-poll address of [install]'s mailbox for [role] on a relay.
typedef MailboxUri = Uri Function(String install, String role);

/// [MailboxDoor] over the existing long-poll lane.
class RelayMailboxDoor implements MailboxDoor {
  RelayMailboxDoor({required this.uriFor, this.requestTimeout});

  /// The relay the app's fallback lanes already point at: the same URL
  /// shape `ResilientLaneEndpoints.cloudflareWorker` gives a call, with
  /// the install id where the call id would be.
  factory RelayMailboxDoor.borderRelay(String relayHost) => RelayMailboxDoor(
    uriFor: (install, role) => ResilientLaneEndpoints.cloudflareWorker(
      workerHost: relayHost,
      session: install,
      role: role,
    ).longPollUri!,
  );

  final MailboxUri uriFor;
  final Duration? requestTimeout;
  final Map<String, HttpLongPollLane> _lanes = <String, HttpLongPollLane>{};
  bool _disposed = false;

  HttpLongPollLane _lane(String install, String role) =>
      _lanes['$role:$install'] ??= HttpLongPollLane(
        sendUri: uriFor(install, role),
        requestTimeout: requestTimeout ?? const Duration(seconds: 8),
      );

  @override
  Future<bool> deposit(String install, Uint8List box) async {
    if (_disposed) return false;
    // Side `a` writes; what it writes waits for side `b`.
    return (await _lane(install, 'a').send(box)).delivered;
  }

  @override
  Future<Uint8List?> take(
    String install, {
    Duration wait = Duration.zero,
  }) async {
    if (_disposed) return null;
    return _lane(install, 'b').receive(wait: wait);
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    final lanes = _lanes.values.toList();
    _lanes.clear();
    for (final lane in lanes) {
      await lane.dispose();
    }
  }
}
