import 'dart:async';
import 'dart:collection';

import 'package:crypto/crypto.dart';

import 'data_channel_port.dart';

/// Merges several [DataChannelPort]s (independent network lanes) into one
/// logical [BufferedDataChannelPort], so an existing sender (ReliableMessenger,
/// StagedPhotoTransfer, VideoNoteTransfer) can consume many lanes unmodified.
///
/// This class knows nothing about lane ranking, [DeliveryPlan] or
/// `connection_orchestrator` — it only knows a `List<DataChannelPort>` and an
/// externally-supplied "which one is active right now" callback. Whoever
/// wires this up (outside this package) decides the active lane and updates
/// it as lane health changes; this class just mechanizes:
///  * first transmission of a byte sequence -> the active member only.
///  * a byte-identical resend of that same sequence -> the top-K members
///    (active first, then the rest in list order), so a retransmission gets
///    a real second path instead of retrying the same possibly-broken one.
///  * inbound convergence: data arriving on ANY member surfaces once on this
///    port's merged [inbound] stream.
///  * [bufferedAmount]: the ACTIVE member's backlog only, never a sum —
///    summing would make an idle-but-backlogged second lane look like this
///    stream's own backlog and stall reliable_messenger.dart's backpressure
///    check (`_hasLeftBuffer`, reliable_messenger.dart:435-439).
class LaneSetPort implements BufferedDataChannelPort {
  LaneSetPort(
    this.members, {
    required this.activeIndex,
    int fanout = 2,
    this.alwaysDuplicate = false,
  }) : assert(members.isNotEmpty, 'LaneSetPort needs at least one member') {
    this.fanout = fanout.clamp(1, members.length);
    for (final member in members) {
      _memberSubs.add(
        member.inbound.listen(
          _inboundController.add,
          onError: _inboundController.addError,
        ),
      );
    }
  }

  /// The lanes this port merges. 2 or more in the intended use; a single
  /// member is supported too (see [fanout] clamp) as a degenerate fallback.
  final List<DataChannelPort> members;

  /// Returns the index into [members] that is "active" right now — i.e.
  /// where a first transmission goes. Supplied and updated by the caller
  /// (this class has no lane-health opinion of its own). Out-of-range
  /// values are clamped rather than thrown on, so a stale index during a
  /// lane swap degrades to "pin to an edge lane" instead of crashing a send.
  final int Function() activeIndex;

  /// How many members a RETRANSMISSION (or, with [alwaysDuplicate], every
  /// send) fans out to. Clamped to `[1, members.length]` in the
  /// constructor — never crashes on a small [members] list.
  late final int fanout;

  /// When true, every send (not just a detected retransmission) fans out to
  /// the top [fanout] members. Off by default (media's safe default: only
  /// duplicate work that is already a retry); a caller sending small, cheap
  /// text frames may opt in.
  final bool alwaysDuplicate;

  final StreamController<List<int>> _inboundController =
      StreamController<List<int>>.broadcast();
  final List<StreamSubscription<List<int>>> _memberSubs = [];

  /// Bounded recency cache of sent-frame digests, used to tell a first
  /// transmission from a byte-identical resend without knowing anything
  /// about the wire protocol above us. A [LinkedHashSet] gives O(1)
  /// membership plus cheap "move to most-recently-used" via remove+re-add.
  final LinkedHashSet<String> _recentDigests = LinkedHashSet<String>();
  static const int _historyLimit = 64;

  @override
  Stream<List<int>> get inbound => _inboundController.stream;

  @override
  Future<void> send(List<int> frame) async {
    final digest = sha256.convert(frame).toString();
    final isRetransmit = _recentDigests.contains(digest);
    // Refresh recency (move-to-end) and evict the oldest past the cap —
    // FIFO-ish, bounded, so a long session never grows this unboundedly.
    _recentDigests.remove(digest);
    _recentDigests.add(digest);
    if (_recentDigests.length > _historyLimit) {
      _recentDigests.remove(_recentDigests.first);
    }

    final targets = (alwaysDuplicate || isRetransmit)
        ? _fanoutIndices(fanout)
        : [_clampedActive()];
    if (targets.length == 1) {
      await members[targets.single].send(frame);
      return;
    }
    await Future.wait(targets.map((i) => members[i].send(frame)));
  }

  /// The active member first, then the rest in list order, up to [k] total.
  /// No ranking knowledge beyond "which one is active" — deterministic and
  /// cheap, on purpose.
  List<int> _fanoutIndices(int k) {
    final active = _clampedActive();
    final out = <int>[active];
    for (var i = 0; i < members.length && out.length < k; i++) {
      if (i != active) out.add(i);
    }
    return out;
  }

  int _clampedActive() {
    if (members.length == 1) return 0;
    final raw = activeIndex();
    if (raw < 0) return 0;
    if (raw >= members.length) return members.length - 1;
    return raw;
  }

  @override
  int? get bufferedAmount {
    final active = members[_clampedActive()];
    return active is BufferedDataChannelPort ? active.bufferedAmount : null;
  }

  @override
  Future<void> close() async {
    for (final sub in _memberSubs) {
      await sub.cancel();
    }
    await _inboundController.close();
    await Future.wait(members.map((m) => m.close()));
  }
}
