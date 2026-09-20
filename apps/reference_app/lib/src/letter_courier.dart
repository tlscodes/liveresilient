// The letter's carrier in the reference app: one fabric of the fallback
// lanes call_session already configures (relay, long-poll, and the DNS
// TXT-query valve when the build names a zone), driven to one verdict per
// letter. No sidecar, no process, no new port — the lanes are the ones
// the call would use.
//
// Policy, in this order: a live lane that ranks first carries it; when
// every call lane scores negative the door (the valve) carries it; when
// the door is down too the letter is parked in the queue — the app's own
// durable, bounded one, drained with exactly one deliver the first time
// the door ranks usable again. Every phase is bounded, so the banner always ends
// on a verdict and never on a spinner. A letter the fabric reports sent
// live is written to the ledger as the same bytes, so the Chats list shows
// it as a message.
import 'dart:async';

import 'package:adaptive_transport/adaptive_transport.dart'
    show HttpLongPollLane, TxtQueryLane, TxtQueryWire, WebSocketRelayLane;
import 'package:connection_orchestrator/connection_orchestrator.dart'
    show
        ConnectionFabric,
        ConnectivitySnapshot,
        DeliveryOutcome,
        LaneStatus,
        FabricMode,
        ResilientFallbackLanes,
        ResilientLaneEndpoints,
        ResilientLaneIds;
import 'package:device_link/device_link.dart'
    show DtnBundleQueue, LinkMessagePriority;
import 'package:flutter/foundation.dart';

import 'letter_composer.dart';
import 'letter_ledger.dart';
import 'letter_queue.dart';

/// How long each phase may take. All finite: a letter never spins.
class LetterCourierBudget {
  const LetterCourierBudget({
    this.select = const Duration(seconds: 60),
    this.carry = const Duration(seconds: 120),
    this.refreshEvery = const Duration(seconds: 12),
  });

  /// Refreshing the fabric until some lane ranks first with a positive
  /// score. On the rig the valve needs one probe round to outrank the two
  /// dead WAN lanes.
  final Duration select;

  /// The carry itself, after which the banner says "gave up".
  final Duration carry;

  /// Gap between refreshes in the select loop, and the period of the door
  /// watch while a letter is parked.
  final Duration refreshEvery;
}

/// What the courier needs of its lane set, behind one seam: the fabric's
/// refresh, snapshot and deliver, the door's session id, and a way to take
/// a bundle the fabric parked back out of its in-memory queue. Tests
/// script one of these; the app assembles [_FabricLanes] from endpoints.
abstract class LetterLanes {
  Future<void> refresh();
  ConnectivitySnapshot get snapshot;
  Future<DeliveryOutcome> deliver(
    Uint8List payload, {
    required String bundleId,
  });

  /// Removes [bundleId] from the fabric's own queue after it answered
  /// queuedForLater, so the courier's durable queue is the only holder and
  /// a later drain cannot send the letter twice.
  void reclaim(String bundleId);

  /// True when the build names a door (a DNS TXT valve).
  bool get hasDoor;

  /// The door's last session id, when the door exists.
  String? get doorSessionId;
  Future<void> dispose();
}

/// The lanes one courier registered, so the valve's session id and the
/// lane objects' dispose are reachable.
class _FabricLanes implements LetterLanes {
  _FabricLanes({
    required this.fabric,
    required this.queue,
    this.wss,
    this.longPoll,
    this.valve,
  });

  final ConnectionFabric fabric;
  final DtnBundleQueue queue;
  final WebSocketRelayLane? wss;
  final HttpLongPollLane? longPoll;
  final TxtQueryLane? valve;

  @override
  Future<void> refresh() => fabric.refresh();

  @override
  ConnectivitySnapshot get snapshot => fabric.snapshot;

  @override
  Future<DeliveryOutcome> deliver(
    Uint8List payload, {
    required String bundleId,
  }) => fabric.deliver(
    payload,
    bundleId: bundleId,
    priority: LinkMessagePriority.callSignal,
  );

  @override
  void reclaim(String bundleId) => queue.acknowledge(bundleId);

  @override
  bool get hasDoor => valve != null;

  @override
  String? get doorSessionId => valve?.lastSessionId;

  @override
  Future<void> dispose() async {
    await fabric.dispose();
    await wss?.dispose();
    await longPoll?.dispose();
    await valve?.dispose();
  }
}

/// Carries letters over the app's own fallback lanes and reports each
/// one's state through [status] (see [LetterState]) and each act through
/// [notes] (raw lines, the same ones the rig peer prints).
class LetterCourier {
  LetterCourier({
    required this.endpoints,
    this.budget = const LetterCourierBudget(),
    this.valveFailThreshold = 20,
    DateTime Function()? now,
    LetterLedger? ledger,
    LetterQueue? queue,
    this._openLanes,
    Future<void> Function(Duration)? wait,
    Timer Function(Duration period, void Function() tick)? schedulePeriodic,
  }) : _now = now ?? DateTime.now,
       ledger = ledger ?? LetterLedger(),
       queue = queue ?? LetterQueue(MemoryLetterQueueStore()),
       _wait = wait ?? ((d) => Future<void>.delayed(d)),
       _schedulePeriodic =
           schedulePeriodic ?? ((d, tick) => Timer.periodic(d, (_) => tick()));

  /// The lane set, built the way the call builds it (call_session's
  /// `defaultBorderRelayEndpoints`), read once per fabric.
  final ResilientLaneEndpoints Function() endpoints;
  final LetterCourierBudget budget;

  /// Probe() is a real send, so the valve's default failure threshold (5)
  /// would declare it DOWN — terminally — inside one select window. Same
  /// value the rig peer uses.
  final int valveFailThreshold;
  final DateTime Function() _now;

  /// Every letter the fabric reported sent live, as the bytes that left.
  final LetterLedger ledger;

  /// Letters parked behind a down door, drained by the watch.
  final LetterQueue queue;

  /// A test's scripted lanes; null builds the fabric from [endpoints].
  final Future<LetterLanes?> Function()? _openLanes;

  /// The select loop's pause and the watch's period, both injectable so
  /// tests advance a clock instead of sleeping.
  final Future<void> Function(Duration) _wait;
  final Timer Function(Duration period, void Function() tick) _schedulePeriodic;

  /// The letter's verdict, null before the first act of a letter.
  final ValueNotifier<LetterStatus?> status = ValueNotifier<LetterStatus?>(
    null,
  );

  /// The last 40 raw lines, newest last.
  final ValueNotifier<List<String>> notes = ValueNotifier<List<String>>(
    const [],
  );

  /// True from Send until the verdict, and while the watch drains a parked
  /// letter; the sheet disables Send meanwhile.
  final ValueNotifier<bool> busy = ValueNotifier<bool>(false);

  /// The fabric's last snapshot — relay, long-poll and door scores, the
  /// mode, the best lane — taken after every refresh the courier already
  /// performs (probe, select, carry, watch). Never a probe of its own:
  /// the thread reads this, it does not touch the network.
  final ValueNotifier<ConnectivitySnapshot?> laneSnapshot =
      ValueNotifier<ConnectivitySnapshot?>(null);

  ConnectivitySnapshot _snap(LetterLanes source) {
    final s = source.snapshot;
    if (!_disposed) laneSnapshot.value = s;
    return s;
  }

  LetterLanes? _lanes;
  Future<LetterLanes?>? _opening;
  Timer? _watch;
  var _ticking = false;
  var _disposed = false;

  void note(String line) {
    final stamped = '${_now().toIso8601String().substring(11, 19)} $line';
    debugPrint('LETTER $line');
    final next = List<String>.of(notes.value)..add(stamped);
    if (next.length > 40) next.removeRange(0, next.length - 40);
    notes.value = next;
  }

  void _set(LetterState state, [String detail = '']) {
    final next = LetterStatus(state, detail);
    status.value = next;
    note('letter state: $next');
  }

  /// One fabric per courier, kept across letters so the door watch has
  /// the same lanes the letter was scored on — disposing after each carry
  /// would drop them (the rig peer does, on purpose: its job ends).
  Future<LetterLanes?> _open() {
    final live = _lanes;
    if (live != null) return Future.value(live);
    return _opening ??= (_openLanes?.call() ?? _assemble())
        .then((lanes) async {
          if (_disposed) {
            // Disposed while assembling: nothing may keep these lanes.
            await lanes?.dispose();
            return null;
          }
          return _lanes = lanes;
        })
        .whenComplete(() => _opening = null);
  }

  Future<LetterLanes?> _assemble() async {
    final e = endpoints();
    final relayUri = e.relayUri;
    final longPollUri = e.longPollUri;
    final valveSpec = e.txtQueryValve;
    final wss = relayUri == null
        ? null
        : WebSocketRelayLane(relayUri: relayUri);
    final longPoll = longPollUri == null
        ? null
        : HttpLongPollLane(sendUri: longPollUri);
    final valve = valveSpec == null
        ? null
        : TxtQueryLane.forValve(valveSpec, failThreshold: valveFailThreshold);
    if (wss == null && longPoll == null && valve == null) {
      note('no lane configured in this build');
      return null;
    }
    final queue = DtnBundleQueue();
    final fabric = ConnectionFabric(
      fallbackQueue: queue,
      nowMs: () => _now().millisecondsSinceEpoch,
    );
    final ids = ResilientFallbackLanes.registerAll(
      fabric,
      webSocketRelay: wss,
      httpLongPoll: longPoll,
      txtQuery: valve,
    );
    note(
      'lanes=${ids.join(',')}'
      '${valveSpec == null ? ' (no door: DNS_VALVE_DOMAIN unset)' : ' zone=${valveSpec.domain}'}',
    );
    return _FabricLanes(
      fabric: fabric,
      queue: queue,
      wss: wss,
      longPoll: longPoll,
      valve: valve,
    );
  }

  static String _scores(ConnectivitySnapshot s) => [
    for (final lane in s.lanes)
      '${lane.id.replaceFirst('resilient.', '')}='
          '${lane.score.toStringAsFixed(2)}${lane.eligible ? '' : '!'}',
  ].join(' ');

  static String _short(String? laneId) =>
      (laneId ?? 'a lane').replaceFirst('resilient.', '');

  /// The fabric's own line between a lane with a path and one without:
  /// `deadLaneScore` is −1.0 minus the cost penalty, so every dead lane
  /// scores at or below −1.0 and every lane with health > 0 scores above
  /// it — a freshly answering door sits at 0.01 − 0.15 = −0.14. "Score > 0"
  /// was the wrong test: measured on the phone 2026-09-20 (real app, the
  /// responder answering every 12 s probe), the letter was parked as "door
  /// down" for 200 s while the door was up. Same trap the fabric records
  /// from 2026-09-13; a third ranking must not disagree with the two.
  static const double _deadAtOrBelow = -1.0;

  static bool _hasPath(LaneStatus lane) =>
      lane.eligible && lane.score > _deadAtOrBelow;

  /// A lane that works right now: eligible, ranked first, has a path.
  static bool _bestIsUsable(ConnectivitySnapshot s) {
    final best = s.bestLaneId;
    if (best == null) return false;
    for (final lane in s.lanes) {
      if (lane.id == best) return _hasPath(lane);
    }
    return false;
  }

  static bool _liveCallReachable(ConnectivitySnapshot s) {
    if (s.mode == FabricMode.offline || s.mode == FabricMode.storeAndForward) {
      return false;
    }
    for (final lane in s.lanes) {
      if (lane.id == ResilientLaneIds.txtQuery) continue;
      if (_hasPath(lane)) return true;
    }
    return false;
  }

  /// One refresh, before the person writes: says whether the live call is
  /// out, so the sheet opens on that verdict instead of a blank.
  Future<void> probe() async {
    if (_disposed) return;
    final lanes = await _open();
    if (lanes == null) {
      _set(LetterState.notDelivered, 'no lane configured in this build');
      return;
    }
    await lanes.refresh();
    final s = _snap(lanes);
    note('probe mode=${s.mode.name} best=${s.bestLaneId} ${_scores(s)}');
    if (!_liveCallReachable(s)) {
      _set(
        LetterState.liveCallUnavailable,
        lanes.hasDoor ? _scores(s) : 'and no door in this build',
      );
    }
  }

  /// Reads the queue's store: a letter parked before a restart is waiting
  /// again, and the watch resumes for it. The app calls this once.
  Future<void> restore() async {
    await queue.ensureLoaded();
    if (_disposed || queue.isEmpty) return;
    note('restored ${queue.length} parked letter(s)');
    _set(LetterState.queued, 'parked in the queue · ${queue.waiting} waiting');
    _startWatch();
  }

  /// Carries [payload] to one verdict. [kind] names it for the notes and
  /// the ledger (typed / voice / photo); [duration] is a voice take's
  /// encoded length, for its label in the Chats list. Returns the final
  /// state.
  Future<LetterState> send(
    Uint8List payload, {
    required String kind,
    Duration? duration,
  }) async {
    if (busy.value) return status.value?.state ?? LetterState.queued;
    busy.value = true;
    try {
      return await _send(payload, kind, duration);
    } finally {
      busy.value = false;
    }
  }

  Future<LetterState> _send(
    Uint8List payload,
    String kind,
    Duration? duration,
  ) async {
    if (payload.length > TxtQueryLane.maxPayloadBytes) {
      _set(
        LetterState.notDelivered,
        'too long — ${payload.length} B, the door takes '
        '${TxtQueryLane.maxPayloadBytes}',
      );
      return LetterState.notDelivered;
    }
    final lanes = await _open();
    if (lanes == null) {
      _set(LetterState.notDelivered, 'no lane configured in this build');
      return LetterState.notDelivered;
    }
    final chunks = TxtQueryWire.splitChunks(payload).length;
    _set(LetterState.queued, '${payload.length} B ($kind) · probing the door');

    // Select: refresh until some lane ranks first with a positive score.
    // A live lane wins as soon as it does; on the rig the two dead WAN
    // lanes score negative and the valve overtakes them after its probe.
    final selectUntil = _now().add(budget.select);
    var refreshes = 0;
    ConnectivitySnapshot s;
    while (true) {
      await lanes.refresh();
      refreshes++;
      s = _snap(lanes);
      if (_bestIsUsable(s) || !_now().isBefore(selectUntil)) break;
      await _wait(budget.refreshEvery);
    }
    if (!_liveCallReachable(s)) {
      _set(LetterState.liveCallUnavailable, _scores(s));
    }
    final best = s.bestLaneId;
    note('selected best=$best refreshes=$refreshes ${_scores(s)}');
    final letter = QueuedLetter(
      id: 'letter-${_now().millisecondsSinceEpoch}',
      bytes: payload,
      kind: kind,
      queuedAt: _now(),
      duration: duration,
    );
    if (!_bestIsUsable(s)) {
      // Every call lane negative and the door down: nothing to carry it
      // now. Parked here, not offered to the fabric, so the one deliver
      // it gets is the watch's.
      return _park(letter);
    }
    _set(
      LetterState.queued,
      '${payload.length} B · $chunks chunks · via ${_short(best)}',
    );
    return _carry(lanes, letter, best, fromQueue: false);
  }

  /// One bounded deliver and its verdict. A letter from the queue leaves
  /// it on sentLive and rejected, and waits for the next door-up on every
  /// other ending.
  Future<LetterState> _carry(
    LetterLanes lanes,
    QueuedLetter letter,
    String? best, {
    required bool fromQueue,
  }) async {
    final payload = letter.bytes;
    final DeliveryOutcome outcome;
    // The fabric's deliver outlives a timeout (`timeout` does not cancel
    // it), so the letter stays in flight until this future settles: no
    // second deliver of the same bundle, no bundle held by both queues.
    final inner = lanes.deliver(payload, bundleId: letter.id);
    try {
      outcome = await inner.timeout(budget.carry);
    } on TimeoutException {
      _set(
        LetterState.notDelivered,
        'gave up after ${budget.carry.inSeconds}s · ${_scores(_snap(lanes))}',
      );
      unawaited(_settleLate(inner, lanes, letter, best, fromQueue: fromQueue));
      return LetterState.notDelivered;
    } on Object catch (error) {
      if (fromQueue) queue.release(letter.id);
      _set(LetterState.notDelivered, 'error: $error');
      return LetterState.notDelivered;
    }
    final session = lanes.doorSessionId;
    note('carried outcome=${outcome.name} session=$session');
    switch (outcome) {
      case DeliveryOutcome.sentLive:
        final throughDoor = best == ResilientLaneIds.txtQuery;
        if (fromQueue) await queue.remove(letter.id);
        _record(letter, best, throughDoor ? session : null);
        _set(
          LetterState.arrived,
          throughDoor && session != null
              ? '${payload.length} B · through the door · session $session'
              : '${payload.length} B · via ${_short(best)}',
        );
        return LetterState.arrived;
      case DeliveryOutcome.queuedForLater:
        // The fabric parked it in memory; the durable queue takes custody.
        lanes.reclaim(letter.id);
        if (fromQueue) {
          queue.release(letter.id);
          _set(
            LetterState.queued,
            '${payload.length} B · door down again · ${queue.waiting} waiting',
          );
        } else {
          return _park(letter);
        }
        return LetterState.queued;
      case DeliveryOutcome.rejected:
        if (fromQueue) await queue.remove(letter.id);
        _set(LetterState.notDelivered, 'refused by the queue');
        return LetterState.notDelivered;
    }
  }

  Future<LetterState> _park(QueuedLetter letter) async {
    if (!await queue.enqueue(letter)) {
      _set(
        LetterState.notDelivered,
        'queue full · ${queue.length} parked behind the door',
      );
      return LetterState.notDelivered;
    }
    _set(
      LetterState.queued,
      '${letter.bytes.length} B · door down · parked in the queue · '
      '${queue.waiting} waiting',
    );
    _startWatch();
    return LetterState.queued;
  }

  void _record(QueuedLetter letter, String? laneId, String? sessionId) {
    ledger.add(
      LetterRecord(
        bytes: letter.bytes,
        kind: letter.kind,
        sentAt: _now(),
        laneId: laneId,
        sessionId: sessionId,
        duration: letter.duration,
      ),
    );
  }

  /// A deliver that outran [LetterCourierBudget.carry]: the banner already
  /// said "gave up", but the fabric is still carrying, so the letter keeps
  /// its in-flight mark until the answer comes. sentLive is recorded as
  /// any other; queuedForLater moves custody to the durable queue; only a
  /// verdict (or an error) lets a queued letter be offered again.
  Future<void> _settleLate(
    Future<DeliveryOutcome> inner,
    LetterLanes lanes,
    QueuedLetter letter,
    String? best, {
    required bool fromQueue,
  }) async {
    final DeliveryOutcome late;
    try {
      late = await inner;
    } on Object catch (error) {
      if (_disposed) return;
      note('late error for ${letter.id}: $error');
      if (fromQueue) queue.release(letter.id);
      return;
    }
    if (_disposed) return;
    final session = lanes.doorSessionId;
    note('late outcome=${late.name} for ${letter.id} session=$session');
    switch (late) {
      case DeliveryOutcome.sentLive:
        if (fromQueue) await queue.remove(letter.id);
        final throughDoor = best == ResilientLaneIds.txtQuery;
        _record(letter, best, throughDoor ? session : null);
        if (!busy.value) {
          _set(
            LetterState.arrived,
            '${letter.bytes.length} B · late · '
            '${throughDoor && session != null ? 'through the door · session $session' : 'via ${_short(best)}'}',
          );
        }
      case DeliveryOutcome.queuedForLater:
        lanes.reclaim(letter.id);
        if (fromQueue) {
          queue.release(letter.id);
        } else {
          await _park(letter);
        }
      case DeliveryOutcome.rejected:
        if (fromQueue) await queue.remove(letter.id);
    }
  }

  /// The door watch: while a letter is parked, refresh every
  /// [LetterCourierBudget.refreshEvery] and, the first time the best lane
  /// ranks usable, drain the head of the queue with one deliver. Stops
  /// by itself when the queue is empty.
  void _startWatch() {
    if (_watch != null || _disposed) return;
    _watch = _schedulePeriodic(budget.refreshEvery, () => unawaited(_tick()));
  }

  void _stopWatch() {
    _watch?.cancel();
    _watch = null;
  }

  Future<void> _tick() async {
    if (_disposed || _ticking) return;
    if (queue.isEmpty) {
      _stopWatch();
      return;
    }
    // A fresh Send owns the lanes; its own verdict re-arms the watch.
    // Held from here, before the first await: the sheet's Send is disabled
    // for the whole tick, so no letter can start a carry beside this one.
    if (busy.value) return;
    _ticking = true;
    busy.value = true;
    try {
      final lanes = await _open();
      if (lanes == null) {
        _stopWatch();
        return;
      }
      try {
        await lanes.refresh();
      } on Object catch (error) {
        // The fabric was disposed under a tick already running; the watch
        // is cancelled with it and nothing here may throw past the timer.
        if (!_disposed) note('watch refresh failed: $error');
        return;
      }
      if (_disposed) return;
      final s = _snap(lanes);
      if (!_bestIsUsable(s)) return;
      final head = queue.take();
      if (head == null) return;
      note(
        'door up · draining ${head.id} via ${_short(s.bestLaneId)} '
        '${_scores(s)}',
      );
      await _carry(lanes, head, s.bestLaneId, fromQueue: true);
    } finally {
      if (!_disposed) busy.value = false;
      _ticking = false;
      if (queue.isEmpty) _stopWatch();
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    _stopWatch();
    final lanes = _lanes;
    _lanes = null;
    await lanes?.dispose();
    status.dispose();
    notes.dispose();
    busy.dispose();
    laneSnapshot.dispose();
    ledger.dispose();
    queue.dispose();
  }
}
