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
    show
        HttpLongPollLane,
        TxtLetterProbe,
        TxtProbeOutcome,
        TxtQueryLane,
        TxtQueryWire,
        WebSocketRelayLane,
        withFallbackIfDoorAbsent;
import 'package:connection_orchestrator/connection_orchestrator.dart'
    show
        CallHistoryRecord,
        CallHistoryStore,
        ConnectionFabric,
        ConnectivitySnapshot,
        DeliveryOutcome,
        LaneStatus,
        FabricMode,
        NetworkAtlas,
        ResilientFallbackLanes,
        ResilientLaneEndpoints,
        ResilientLaneIds;
import 'package:device_link/device_link.dart'
    show DtnBundleQueue, LinkMessagePriority;
import 'package:flutter/foundation.dart';

import 'intelligence/network_name_resolver.dart' show NetworkNameResolver;
import 'letter_card.dart';
import 'letter_composer.dart';
import 'letter_parts.dart';
import 'letter_status_ladder.dart';
import 'letter_ledger.dart';
import 'letter_queue.dart';
import 'letter_rung_ladder.dart';

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
/// Lanes that can race the door's resolvers before a letter goes out
/// (TxtLetterProbe): three resolvers, one nonce each, and the nonce our
/// responder LOGGED first names the resolver the letter starts on.
abstract interface class LetterDoorProbe {
  /// Null when there is no door. The door's next exchange is already
  /// pointed at the winner when this returns one.
  Future<TxtProbeOutcome?> probeDoor();
}

class _FabricLanes implements LetterLanes, LetterDoorProbe {
  _FabricLanes({
    required this.fabric,
    required this.queue,
    this.wss,
    this.longPoll,
    this.valve,
    this.doorResolverLadder,
    this.networkResolver,
  });

  final ConnectionFabric fabric;
  final DtnBundleQueue queue;
  final WebSocketRelayLane? wss;
  final HttpLongPollLane? longPoll;
  final TxtQueryLane? valve;

  /// The valve's own resolvers' win/attempt memory, one level under the
  /// courier's top-level rung ladder. Null keeps every probe a full,
  /// parallel race of every candidate — today's behaviour.
  final DoorResolverLadder? doorResolverLadder;

  /// Same network label the top-level ladder uses, so both levels agree
  /// on which place's memory they are reading.
  final NetworkNameResolver? networkResolver;

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
  Future<TxtProbeOutcome?> probeDoor() async {
    final lane = valve;
    if (lane == null) return null;
    var probe = TxtLetterProbe.forLane(lane);
    // The fixed race is untouched: widened only when none of the door's
    // usual public resolvers made it into today's candidate set, then —
    // on a history-bearing network — narrowed to the previous winner and
    // its close rivals by win rate (DoorResolverLadder.narrow, the one
    // rule letter_rung_ladder_test pins). A previous winner absent from
    // today's candidates falls back to the full race, unchanged.
    var transports = withFallbackIfDoorAbsent(probe.transports);
    final ladder = doorResolverLadder;
    final label = ladder == null
        ? null
        : (await networkResolver?.resolveNetworkLabel()) ?? 'unknown';
    if (ladder != null && label != null) {
      final history = await ladder.history(label);
      if (history.isNotEmpty) {
        transports = DoorResolverLadder.narrow(
          transports,
          (t) => t.label,
          history,
          await ladder.previousWinner(label),
        );
      }
    }
    if (!identical(transports, probe.transports)) {
      probe = TxtLetterProbe(
        domain: probe.domain,
        transports: transports,
        timeout: probe.timeout,
      );
    }
    final outcome = await probe.run();
    final w = outcome.winnerIndex;
    if (w != null) lane.preferTransport(probe.transports[w]);
    if (ladder != null && label != null) {
      await ladder.record(
        label,
        asked: [for (final t in probe.transports) t.label],
        winner: w == null ? null : probe.transports[w].label,
      );
    }
    return outcome;
  }

  @override
  Future<void> dispose() async {
    await fabric.dispose();
    await wss?.dispose();
    await longPoll?.dispose();
    await valve?.dispose();
  }
}

/// The rung word every letter banner ends with — the same [bannerName]
/// the Director says. With [nextProbeIn], a closed rung also names the
/// watch's next probe: a reading of its existing schedule, never a
/// reason to run one sooner.
String _rungSuffix(LetterLadderStatus? status, {Duration? nextProbeIn}) =>
    switch ((status?.rung, nextProbeIn)) {
      (null, _) => '',
      (LetterLadderRung.closed, final next?) =>
        ' · closed · next probe in ${next.inSeconds}s',
      (final rung?, _) => ' · ${rung.bannerName}',
    };

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
    this._networkResolver,
    this._rungLadder,
    this._doorResolverLadder,
    this._measurementConsent,
    this._installMeasurement,
    this._callHistory,
    this._cardSink,
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

  /// Names the current network so [_rungLadder]'s memory is per-place,
  /// not global. Null keeps the ladder inert even when one is given.
  final NetworkNameResolver? _networkResolver;

  /// The rung that last delivered on this network, tried alone before
  /// the fabric's own ranking; null keeps today's behaviour unchanged —
  /// whichever lane the fabric ranks first, every time.
  final LetterRungLadder? _rungLadder;

  /// The DNS valve's own resolver ladder, one level under [_rungLadder];
  /// null keeps every door probe a full race of every resolver.
  final DoorResolverLadder? _doorResolverLadder;

  /// Gates [_installMeasurement]; null (the default) means no consent
  /// object was wired in, which the recorder treats as withheld.
  final LetterMeasurementConsent? _measurementConsent;

  /// The once-per-install-lifetime measurement; null keeps every Send
  /// exactly as it is today, nothing extra written anywhere.
  final InstallLetterMeasurement? _installMeasurement;

  /// The SAME call-history store nightly_evolution replays — every
  /// delivered or queued letter appends one call-history-shaped row
  /// (identityHash, rung, resolver, rtt, outcome; never letter text).
  /// Null keeps letters out of that history entirely.
  final CallHistoryStore? _callHistory;

  /// One lab measurement card per Send (letter_card.dart): counts and ids
  /// only, never letter text. Null keeps every Send exactly as today.
  final LetterCardSink? _cardSink;

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

  /// The letter path's own six-rung reading (letter_status_ladder.dart),
  /// from this same snapshot and the door probe's own outcome. Read-only:
  /// updating it never runs a probe, never arms a timer — "closed" is a
  /// report of the existing queue and existing next-probe schedule, not
  /// a reason to make either happen sooner.
  final ValueNotifier<LetterLadderStatus?> ladderStatus =
      ValueNotifier<LetterLadderStatus?>(null);

  /// Cycle B: consecutive failed carries per lane. Two in a row evict the
  /// lane from selection until its next healthy answer (arrived, or a
  /// door probe our responder logged). A lane that loses its path starts
  /// over: its strikes and eviction are cleared.
  final Map<String, int> _strikes = <String, int>{};
  final Set<String> _evicted = <String>{};

  void _strike(String laneId, {required bool healthy}) {
    if (healthy) {
      _strikes.remove(laneId);
      _evicted.remove(laneId);
      return;
    }
    final n = (_strikes[laneId] ?? 0) + 1;
    _strikes[laneId] = n;
    if (n >= 2) _evicted.add(laneId);
  }

  /// The fabric's best lane, unless evicted; then the next lane, best
  /// first, that has a path and is not evicted; null when none.
  String? _pick(ConnectivitySnapshot raw) {
    final best = raw.bestLaneId;
    if (best == null || !_evicted.contains(best)) return best;
    for (final lane in raw.lanes) {
      if (_hasPath(lane) && !_evicted.contains(lane.id)) return lane.id;
    }
    return null;
  }

  ConnectivitySnapshot _snap(LetterLanes source) {
    final raw = source.snapshot;
    for (final lane in raw.lanes) {
      if (!_hasPath(lane)) {
        _strikes.remove(lane.id);
        _evicted.remove(lane.id);
      }
    }
    final bestLaneId = _pick(raw);
    final s = bestLaneId == raw.bestLaneId
        ? raw
        : ConnectivitySnapshot(
            mode: raw.mode,
            lanes: raw.lanes,
            bestLaneId: bestLaneId,
            pendingBundles: raw.pendingBundles,
            atMs: raw.atMs,
          );
    if (!_disposed) laneSnapshot.value = s;
    return s;
  }

  /// The one network label every ladder read resolves through — Send,
  /// probe() and the watch's tick all go through here, so the door history
  /// they read agrees on the same snapshot. Null (no ladder / measurement /
  /// call history configured) keeps today's behaviour: the door history is
  /// not consulted.
  Future<String?> _sendNetworkLabel() async {
    final needs =
        _rungLadder != null ||
        _installMeasurement != null ||
        _callHistory != null;
    return needs
        ? (await _networkResolver?.resolveNetworkLabel()) ?? 'unknown'
        : null;
  }

  /// Recomputes [ladderStatus] from [s] and, when the door raced this
  /// round, [probe]. [_doorResolverLadder]'s history is read, never
  /// written, here. When the caller passes no [networkLabel] (probe() and
  /// the watch's tick), this resolves the same label Send uses, so all
  /// three read the door history under the same key — the pre-send banner,
  /// a drained letter and Send no longer disagree on the same snapshot.
  Future<void> _updateLadder(
    ConnectivitySnapshot s, {
    TxtProbeOutcome? probe,
    String? networkLabel,
  }) async {
    final doorLadder = _doorResolverLadder;
    final label =
        networkLabel ?? (doorLadder == null ? null : await _sendNetworkLabel());
    final history = (doorLadder == null || label == null)
        ? const <String, ({int wins, int attempts})>{}
        : await doorLadder.history(label);
    if (_disposed) return;
    ladderStatus.value = _applyDegradedLatch(
      classifyLetterLadder(
        snapshot: s,
        lastProbe: probe,
        doorHistory: history,
        queueWaiting: queue.waiting,
        nextProbeIn: budget.refreshEvery,
      ),
    );
  }

  /// Hysteresis. Once a deliver has outrun [LetterCourierBudget.carry] —
  /// a "gave up" / late verdict — this courier instance never reports a
  /// rung better than weak again: a degraded run stays marked degraded,
  /// so a healthy IMMEDIATE reply right after does not erase it. No new
  /// rung, no new number — it reuses [LetterLadderRung.weak] with reason
  /// 'late'. Lifetime is this courier instance (the app process); a fresh
  /// process starts clean.
  bool _degradedLatch = false;

  LetterLadderStatus _applyDegradedLatch(LetterLadderStatus next) =>
      _degradedLatch && next.rung.index < LetterLadderRung.weak.index
      ? const LetterLadderStatus(LetterLadderRung.weak, reason: 'late')
      : next;

  void _markDegraded() {
    _degradedLatch = true;
    final current = ladderStatus.value;
    if (current != null) ladderStatus.value = _applyDegradedLatch(current);
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

  void _set(LetterState state, [String detail = '', double? progress]) {
    final next = LetterStatus(state, detail, progress);
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
      doorResolverLadder: _doorResolverLadder,
      networkResolver: _networkResolver,
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
  /// from 2026-09-13; a third ranking must not disagree with the two —
  /// so the constant lives once, in letter_status_ladder.dart, and both
  /// this selection and the status ladder read it.
  static bool _hasPath(LaneStatus lane) => letterLaneHasPath(lane);

  /// Whether [laneId] specifically has a path right now — the previous
  /// winner's own check, independent of which lane the fabric currently
  /// ranks first.
  static bool _hasPathFor(ConnectivitySnapshot s, String laneId) {
    for (final lane in s.lanes) {
      if (lane.id == laneId) return _hasPath(lane);
    }
    return false;
  }

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
    // The sheet opens on a rung too — read from this same refresh, no
    // probe of its own.
    await _updateLadder(s);
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
    // Over the cap: up to ten letters in a row (letter_parts.dart), each
    // under the cap, which itself is untouched. Refused before any lane is
    // touched when even ten would not do.
    final List<Uint8List> parts;
    try {
      parts = splitLetter(payload, maxPartBytes: TxtQueryLane.maxPayloadBytes);
    } on LetterTooLong catch (e) {
      _set(
        LetterState.notDelivered,
        'too long — ${payload.length} B, the door takes $letterMaxParts '
        'letters of ${TxtQueryLane.maxPayloadBytes} (${e.limit} B)',
      );
      return LetterState.notDelivered;
    }
    final lanes = await _open();
    if (lanes == null) {
      _set(LetterState.notDelivered, 'no lane configured in this build');
      return LetterState.notDelivered;
    }
    var chunks = 0;
    for (final p in parts) {
      chunks += TxtQueryWire.splitChunks(p).length;
    }
    _set(LetterState.queued, '${payload.length} B ($kind) · probing the door');

    // The ladder's memory: the rung that last delivered on THIS network,
    // tried alone before the fabric's own ranking. Null resolver/ladder
    // (the default) keeps today's behaviour: whichever lane the fabric
    // ranks first, every time.
    final ladder = _rungLadder;
    final measurement = _installMeasurement;
    final networkLabel = await _sendNetworkLabel();
    final previousWinner = ladder == null || networkLabel == null
        ? null
        : await ladder.previousWinner(networkLabel);
    // An evicted previous winner is not offered ahead of the ranking.
    bool winnerReady(ConnectivitySnapshot s) =>
        previousWinner != null &&
        !_evicted.contains(previousWinner) &&
        _hasPathFor(s, previousWinner);

    // Select: refresh until the previous winner has a path again, or
    // some lane ranks first with a positive score. A live lane wins as
    // soon as it does; on the rig the two dead WAN lanes score negative
    // and the valve overtakes them after its probe.
    final selectUntil = _now().add(budget.select);
    var refreshes = 0;
    ConnectivitySnapshot s;
    while (true) {
      await lanes.refresh();
      refreshes++;
      s = _snap(lanes);
      if (winnerReady(s) || _bestIsUsable(s) || !_now().isBefore(selectUntil)) {
        break;
      }
      await _wait(budget.refreshEvery);
    }
    if (!_liveCallReachable(s)) {
      _set(LetterState.liveCallUnavailable, _scores(s));
    }
    final viaWinner = winnerReady(s);
    final best = viaWinner
        ? previousWinner
        : (_bestIsUsable(s) ? s.bestLaneId : null);
    note(
      'selected best=$best refreshes=$refreshes '
      '${viaWinner ? 'previous winner · ' : ''}${_scores(s)}',
    );
    final attemptStart = _now();
    final letter = QueuedLetter(
      id: 'letter-${_now().millisecondsSinceEpoch}',
      bytes: payload,
      kind: kind,
      queuedAt: _now(),
      duration: duration,
    );
    await _updateLadder(s, networkLabel: networkLabel);
    if (best == null) {
      // Every call lane negative and the door down: nothing to carry it
      // now. Parked here, not offered to the fabric, so the one deliver
      // it gets is the watch's. The decision (closed → queued) and its
      // reason go on the card too, from the rung just computed above.
      _recordCard(
        bytes: payload.length,
        state: LetterState.queued,
        bestLane: null,
      );
      return _park(letter);
    }
    String? doorResolver;
    // Kept past the race for the letter's card: its labels are the
    // resolvers this Send raced. Never a second probe.
    TxtProbeOutcome? probe;
    if (best == ResilientLaneIds.txtQuery && lanes is LetterDoorProbe) {
      // The door carries it: race three resolvers first. The winner is the
      // nonce our responder logged first, not the first answer home; none
      // logged means none of them reaches us now, so the letter waits.
      _set(LetterState.queued, '${payload.length} B · racing 3 resolvers');
      probe = await (lanes as LetterDoorProbe).probeDoor();
      if (probe != null) {
        note('probe ${probe.describe()}');
        // The evidence, journaled before the carry: what was asked, what
        // came back, and why the rest did not. Decides nothing; best
        // effort like the card, never able to break the Send.
        final Object? proofSink = _cardSink;
        if (proofSink is LetterProofSink) {
          try {
            unawaited(
              proofSink
                  .appendProof(LetterProof.fromProbe(probe, at: _now()))
                  .catchError((Object _) {}),
            );
          } catch (_) {}
        }
        await _updateLadder(s, probe: probe, networkLabel: networkLabel);
        if (!probe.reachedServer) {
          // A probe miss is one strike for the door (cycle B).
          _strike(best, healthy: false);
          final rttMs = _now().difference(attemptStart).inMilliseconds;
          _recordRung(
            networkLabel,
            ladder,
            best,
            latencyMs: rttMs,
            delivered: false,
          );
          _recordInstallMeasurement(
            measurement,
            networkLabel,
            best,
            rttMs: rttMs,
            delivered: false,
          );
          _recordCallHistory(
            networkLabel,
            best,
            rttMs: rttMs,
            delivered: false,
          );
          final parked = await _park(letter);
          _recordCard(
            bytes: payload.length,
            state: LetterState.queued,
            bestLane: best,
            probe: probe,
          );
          return parked;
        }
        // Only a probe win reaches here: a healthy answer clears strikes.
        _strike(best, healthy: probe.reachedServer);
        doorResolver = probe.answers[probe.winnerIndex!].label;
      }
    }
    _set(
      LetterState.queued,
      '${payload.length} B · $chunks chunks · via ${_short(best)}',
    );
    final result = await _carry(lanes, letter, best, fromQueue: false);
    _strike(best, healthy: result == LetterState.arrived);
    final rttMs = _now().difference(attemptStart).inMilliseconds;
    _recordRung(
      networkLabel,
      ladder,
      best,
      resolver: doorResolver,
      latencyMs: rttMs,
      delivered: result == LetterState.arrived,
    );
    _recordInstallMeasurement(
      measurement,
      networkLabel,
      best,
      resolver: doorResolver,
      rttMs: rttMs,
      delivered: result == LetterState.arrived,
    );
    _recordCallHistory(
      networkLabel,
      best,
      resolver: doorResolver,
      rttMs: rttMs,
      delivered: result == LetterState.arrived,
    );
    _recordCard(
      bytes: payload.length,
      state: result,
      bestLane: best,
      session: best == ResilientLaneIds.txtQuery ? lanes.doorSessionId : null,
      probe: probe,
      winner: doorResolver,
    );
    return result;
  }

  /// The letter's lab measurement card (letter_card.dart): counts and ids
  /// only. [state] is normalized to sentLive / queued / notDelivered; the
  /// rung is the six-rung reading already on [ladderStatus]. A no-op when
  /// no [_cardSink] was wired in; never throws into the Send.
  void _recordCard({
    required int bytes,
    required LetterState state,
    required String? bestLane,
    String? session,
    TxtProbeOutcome? probe,
    String? winner,
  }) {
    final sink = _cardSink;
    if (sink == null) return;
    final winnerIndex = probe?.winnerIndex;
    final card = LetterCard(
      at: _now(),
      source: 'phone',
      session: session,
      bytes: bytes,
      outcome: normalizeLetterOutcome(state.name),
      bestLane: bestLane,
      resolvers: [for (final a in probe?.answers ?? const []) a.label],
      winner:
          winner ??
          (winnerIndex == null ? null : probe!.answers[winnerIndex].label),
      rung: ladderStatus.value?.rung.name,
      reason: ladderStatus.value?.reason,
      action: switch (state) {
        LetterState.arrived => 'send',
        LetterState.queued => 'queue',
        _ => 'hold',
      },
    );
    // Best-effort, like the card log itself: a sink that throws
    // synchronously (disk full on the first touch) or whose append future
    // errors must never break — or leak an uncaught error into — a Send.
    try {
      unawaited(sink.append(card).catchError((Object _) {}));
    } catch (_) {}
  }

  /// Every delivered or queued letter appends one call-history-shaped
  /// row — identityHash, rung, resolver, rtt, outcome — to the SAME
  /// store [nightly_evolution.dart]'s champion/challenger replay reads.
  /// No letter text, no bundle id. A no-op when [_callHistory] or
  /// [networkLabel] is absent.
  void _recordCallHistory(
    String? networkLabel,
    String rung, {
    String? resolver,
    required int rttMs,
    required bool delivered,
  }) {
    final store = _callHistory;
    if (store == null || networkLabel == null) return;
    store.add(
      CallHistoryRecord(
        startedUtcMs: _now().millisecondsSinceEpoch,
        connectMs: rttMs,
        recoveries: 0,
        dropsToFloor: 0,
        networkIdentityHash: NetworkAtlas.identityHash(networkLabel),
        endReason: delivered ? 'delivered' : 'queued',
        rung: rung,
        resolver: resolver,
      ),
    );
  }

  /// The once-per-install-lifetime measurement's call site: same rung,
  /// resolver and latency the top-level ladder already has, split into
  /// operator/network-type by [splitNetworkLabel]. A no-op when
  /// [measurement] or [networkLabel] is absent, or [recordOnce] itself
  /// finds consent withheld or a row already on disk.
  void _recordInstallMeasurement(
    InstallLetterMeasurement? measurement,
    String? networkLabel,
    String rung, {
    String? resolver,
    required int rttMs,
    required bool delivered,
  }) {
    if (measurement == null || networkLabel == null) return;
    final (networkType, operatorName) = splitNetworkLabel(networkLabel);
    unawaited(
      measurement.recordOnce(
        consent: _measurementConsent,
        networkLabel: networkLabel,
        operatorName: operatorName ?? '',
        networkType: networkType,
        rung: rung,
        resolver: resolver,
        rttMs: rttMs,
        delivered: delivered,
      ),
    );
  }

  /// Appends one row to [ladder]'s history for [networkLabel] and, only
  /// on [delivered], stores [rung] as the next Send's previous winner. A
  /// no-op when the ladder (or its network label) is absent.
  void _recordRung(
    String? networkLabel,
    LetterRungLadder? ladder,
    String rung, {
    String? resolver,
    int? latencyMs,
    required bool delivered,
  }) {
    if (ladder == null || networkLabel == null) return;
    unawaited(
      ladder.record(
        networkLabel,
        LetterRungAttempt(
          rung: rung,
          resolver: resolver,
          latencyMs: latencyMs,
          outcome: delivered
              ? LetterRungOutcome.delivered
              : LetterRungOutcome.queued,
        ),
      ),
    );
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
    if (payload.length > TxtQueryLane.maxPayloadBytes) {
      final List<Uint8List> parts;
      try {
        parts = splitLetter(
          payload,
          maxPartBytes: TxtQueryLane.maxPayloadBytes,
        );
      } on LetterTooLong {
        if (fromQueue) await queue.remove(letter.id);
        _set(LetterState.notDelivered, 'too long for $letterMaxParts letters');
        return LetterState.notDelivered;
      }
      return _carryParts(lanes, letter, parts, best, fromQueue: fromQueue);
    }
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
      // The carry outran its budget: this run degraded. Latch it so a
      // later healthy reply cannot raise the rung back above weak.
      _markDegraded();
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
        final carried = throughDoor && session != null
            ? '${payload.length} B · through the door · session $session'
            : '${payload.length} B · via ${_short(best)}';
        _set(LetterState.arrived, '$carried${_rungSuffix(ladderStatus.value)}');
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

  /// How many parts may be in flight at once. Three: the door answers
  /// each chunk, so three letters interleave without starving one another
  /// on the rig, and the receiver takes any order.
  static const int partsInFlight = 3;

  /// Retries per index before the whole letter gives up.
  static const int partRetries = 2;

  /// The parts of one letter: up to [partsInFlight] delivers at once, each
  /// index its own attempt — a lost part (timeout, refused) is sent again
  /// under the same index and a fresh bundle id, never the whole letter.
  /// The door dropping (queuedForLater) parks the WHOLE letter (a later
  /// carry restarts with a fresh id; the responder drops the stale group
  /// after its deadline), so no half-letter is ever recorded.
  Future<LetterState> _carryParts(
    LetterLanes lanes,
    QueuedLetter letter,
    List<Uint8List> parts,
    String? best, {
    required bool fromQueue,
  }) async {
    final whole = letter.bytes;
    final id = parseLetterPart(parts.first)!.id;
    final n = parts.length;
    final done = List<bool>.filled(n, false);
    final attempts = List<int>.filled(n, 0);
    var landed = 0;
    var doorDown = false;
    String? fatal;
    // Set when at least one part outran budget.carry before the letter
    // gave up — the degraded signal, carried to the give-up site so the
    // latch fires once, symmetric with the single-part _carry (L917).
    var outranBudget = false;
    final inFlight = <Future<void>>{};

    void progress() {
      _set(
        LetterState.queued,
        '${whole.length} B · $landed/$n letters landed · '
        '${inFlight.length} in flight',
        landed / n,
      );
    }

    Future<void> carryIndex(int i) async {
      while (attempts[i] <= partRetries && !doorDown && fatal == null) {
        attempts[i]++;
        final bundleId =
            '${letter.id}-p$i${attempts[i] > 1 ? '-r${attempts[i] - 1}' : ''}';
        DeliveryOutcome outcome;
        try {
          outcome = await lanes
              .deliver(parts[i], bundleId: bundleId)
              .timeout(budget.carry);
        } on TimeoutException {
          outranBudget = true;
          note('letter ${i + 1}/$n gave up (try ${attempts[i]}) — again');
          continue;
        } on Object catch (error) {
          note('letter ${i + 1}/$n error (try ${attempts[i]}): $error');
          continue;
        }
        note(
          'carried letter ${i + 1}/$n try ${attempts[i]} '
          'outcome=${outcome.name} session=${lanes.doorSessionId} '
          'id=${idHex(id)}',
        );
        switch (outcome) {
          case DeliveryOutcome.sentLive:
            done[i] = true;
            landed++;
            return;
          case DeliveryOutcome.queuedForLater:
            lanes.reclaim(bundleId);
            doorDown = true;
            return;
          case DeliveryOutcome.rejected:
            continue;
        }
      }
      if (!done[i] && !doorDown) {
        fatal ??=
            'letter ${i + 1}/$n not taken after ${attempts[i]} tries · '
            '$landed/$n landed';
      }
    }

    var next = 0;
    while ((next < n || inFlight.isNotEmpty) && !doorDown && fatal == null) {
      while (next < n && inFlight.length < partsInFlight && !doorDown) {
        final i = next++;
        late final Future<void> f;
        f = carryIndex(i).whenComplete(() => inFlight.remove(f));
        inFlight.add(f);
      }
      if (inFlight.isEmpty) break;
      progress();
      await Future.any(inFlight);
    }
    // Parts still in flight settle on their own; nothing new is launched.
    await Future.wait(inFlight.toList());

    if (doorDown) {
      if (fromQueue) {
        queue.release(letter.id);
        _set(
          LetterState.queued,
          '${whole.length} B · door down again at $landed/$n letters · '
          '${queue.waiting} waiting',
        );
        return LetterState.queued;
      }
      return _park(letter);
    }
    if (fatal != null) {
      if (fromQueue) queue.release(letter.id);
      _set(LetterState.notDelivered, fatal!);
      // The letter gave up after at least one part outran budget.carry:
      // this run degraded — latch it once, like the single-part _carry.
      if (outranBudget) _markDegraded();
      return LetterState.notDelivered;
    }
    if (fromQueue) await queue.remove(letter.id);
    final throughDoor = best == ResilientLaneIds.txtQuery;
    _record(letter, best, throughDoor ? idHex(id) : null);
    _set(
      LetterState.arrived,
      '${whole.length} B · $n letters, $partsInFlight at a time · '
      '${throughDoor ? 'through the door · id ${idHex(id)}' : 'via ${_short(best)}'}'
      '${_rungSuffix(ladderStatus.value)}',
    );
    return LetterState.arrived;
  }

  Future<LetterState> _park(QueuedLetter letter) async {
    if (!await queue.enqueue(letter)) {
      _set(
        LetterState.notDelivered,
        'queue full · ${queue.length} parked behind the door',
      );
      return LetterState.notDelivered;
    }
    // Rung 6 (closed) alone names the next probe — a reading of the
    // watch's own schedule, never a reason to run one sooner.
    _set(
      LetterState.queued,
      '${letter.bytes.length} B · door down · parked in the queue · '
      '${queue.waiting} waiting'
      '${_rungSuffix(ladderStatus.value, nextProbeIn: budget.refreshEvery)}',
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
      // The rung left from the Send that parked it (often "closed") would
      // otherwise ride onto this letter's arrived banner.
      await _updateLadder(s);
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
    ladderStatus.dispose();
    ledger.dispose();
    queue.dispose();
  }
}
