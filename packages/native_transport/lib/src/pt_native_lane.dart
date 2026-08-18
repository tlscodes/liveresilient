/// A [TransportChannel] backed by the native transport session.
///
/// SCOPE — READ THIS FIRST. `TransportChannel` as it stands declares no
/// receive path: it has `send`, `probe`, `health` and `dispose`, and nothing
/// that delivers inbound bytes. The native library DOES have a receive call.
/// Rather than change a shared interface that every existing lane implements —
/// that is the project owner's decision, not this package's — this lane
/// exposes the receive side as its own [receive] method, outside the
/// interface. Consumers that only hold a `TransportChannel` therefore get a
/// send-only lane; consumers that hold a `PtNativeLane` can also read.
/// This limitation is deliberate and recorded, not an oversight.
library;

import 'dart:typed_data';

import 'package:adaptive_transport/adaptive_transport.dart';

import 'pt_bindings.dart';
import 'pt_common.dart';
import 'pt_session.dart';

// ptNativeLaneName is platform-independent and lives in pt_common.dart so the
// web branch can share it; re-exported here so existing imports keep working.
export 'pt_common.dart' show ptNativeLaneName;

class PtNativeLane implements TransportChannel {
  /// Wraps an already-open [session]. The lane takes ownership: [dispose]
  /// releases the session.
  PtNativeLane(this.session, {ChannelHealth? health})
    : health = health ?? ChannelHealth(reliabilityPrior: 0.5, bandwidth: 0.5);

  /// Opens the library, then a session for [strategy].
  ///
  /// [libraryPath] is the development and test path: a dylib built in the
  /// engine tree. Omitting it selects the shipped path — the
  /// `PtTransport.framework` embedded in the Apple app bundle — because no
  /// build-machine path exists on a user's device. Omitting it on a platform
  /// with no embedded framework throws; it never degrades silently.
  factory PtNativeLane.open({
    String? libraryPath,
    required String strategy,
    String? config,
    ChannelHealth? health,
  }) {
    final bindings = libraryPath == null
        ? PtBindings.openEmbedded()
        : PtBindings.open(libraryPath);
    return PtNativeLane(
      PtSession.open(bindings, strategy: strategy, config: config),
      health: health,
    );
  }

  /// The owned native session. Exposed so a holder of the concrete type can
  /// [receive]; never handed to another isolate.
  final PtSession session;

  @override
  final ChannelHealth health;

  @override
  String get name => ptNativeLaneName;

  /// There is no native health probe, and opening a socket to test liveness
  /// would be a side effect the caller did not ask for. So `probe` reports
  /// only whether this lane is still usable — the session is open and owned by
  /// this isolate. It is NOT a reachability test, and callers must not read it
  /// as one.
  @override
  Future<bool> probe() async => !session.isDisposed;

  @override
  Future<SendResult> send(List<int> payload) async {
    if (session.isDisposed) {
      return const SendResult(SendStatus.unavailable);
    }
    try {
      final written = session.sendAll(payload);
      if (written == payload.length) {
        return const SendResult(SendStatus.ok);
      }
      // A short write that made no further progress is a transient condition,
      // not a permanent failure: the peer may drain and accept the rest.
      return SendResult(
        SendStatus.transient,
        error: 'partial write: $written of ${payload.length} bytes',
      );
    } on PtException catch (e) {
      return SendResult(SendStatus.transient, error: e.message);
    } on StateError catch (e) {
      return SendResult(SendStatus.unavailable, error: e.message);
    }
  }

  /// Reads up to [capacity] bytes. An EMPTY result means nothing was waiting
  /// right now — not end of stream. Outside [TransportChannel] on purpose; see
  /// the library comment.
  Uint8List receive({int capacity = 2048}) => session.recv(capacity);

  @override
  Future<void> dispose() async => session.dispose();
}
