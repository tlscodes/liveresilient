// The letter's carrier in the reference app: one fabric of the fallback
// lanes call_session already configures (relay, long-poll, and the DNS
// TXT-query valve when the build names a zone), driven to one verdict per
// letter. No sidecar, no process, no new port — the lanes are the ones
// the call would use.
//
// Policy, in this order: a live lane that ranks first carries it; when
// every call lane scores negative the door (the valve) carries it; when
// the door is down too the letter is parked in the queue. Every phase is
// bounded, so the banner always ends on a verdict and never on a spinner.
import 'dart:async';

import 'package:adaptive_transport/adaptive_transport.dart'
    show HttpLongPollLane, TxtQueryLane, TxtQueryWire, WebSocketRelayLane;
import 'package:connection_orchestrator/connection_orchestrator.dart'
    show
        ConnectionFabric,
        ConnectivitySnapshot,
        DeliveryOutcome,
        FabricMode,
        ResilientFallbackLanes,
        ResilientLaneEndpoints,
        ResilientLaneIds;
import 'package:device_link/device_link.dart'
    show DtnBundleQueue, LinkMessagePriority;
import 'package:flutter/foundation.dart';

import 'letter_composer.dart';

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

  /// Gap between refreshes in the select loop.
  final Duration refreshEvery;
}

/// The lanes one courier registered, so the valve's session id and the
/// lane objects' dispose are reachable.
class _Lanes {
  _Lanes({required this.fabric, this.wss, this.longPoll, this.valve});

  final ConnectionFabric fabric;
  final WebSocketRelayLane? wss;
  final HttpLongPollLane? longPoll;
  final TxtQueryLane? valve;

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
  }) : _now = now ?? DateTime.now;

  /// The lane set, built the way the call builds it (call_session's
  /// `defaultBorderRelayEndpoints`), read once per fabric.
  final ResilientLaneEndpoints Function() endpoints;
  final LetterCourierBudget budget;

  /// Probe() is a real send, so the valve's default failure threshold (5)
  /// would declare it DOWN — terminally — inside one select window. Same
  /// value the rig peer uses.
  final int valveFailThreshold;
  final DateTime Function() _now;

  /// The letter's verdict, null before the first act of a letter.
  final ValueNotifier<LetterStatus?> status = ValueNotifier<LetterStatus?>(
    null,
  );

  /// The last 40 raw lines, newest last.
  final ValueNotifier<List<String>> notes = ValueNotifier<List<String>>(
    const [],
  );

  /// True from Send until the verdict; the sheet disables Send meanwhile.
  final ValueNotifier<bool> busy = ValueNotifier<bool>(false);

  _Lanes? _lanes;
  Future<_Lanes?>? _opening;
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

  /// One fabric per courier, kept across letters so a bundle the fabric
  /// parked can still drain when the door comes back — disposing after
  /// each carry would drop it (the rig peer does, on purpose: its job ends).
  Future<_Lanes?> _open() {
    final live = _lanes;
    if (live != null) return Future.value(live);
    return _opening ??= _build().whenComplete(() => _opening = null);
  }

  Future<_Lanes?> _build() async {
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
    final fabric = ConnectionFabric(
      fallbackQueue: DtnBundleQueue(),
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
    return _lanes = _Lanes(
      fabric: fabric,
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

  /// A lane that works right now: eligible, ranked first, positive score.
  static bool _bestIsUsable(ConnectivitySnapshot s) {
    final best = s.bestLaneId;
    if (best == null) return false;
    for (final lane in s.lanes) {
      if (lane.id == best) return lane.eligible && lane.score > 0;
    }
    return false;
  }

  static bool _liveCallReachable(ConnectivitySnapshot s) {
    if (s.mode == FabricMode.offline || s.mode == FabricMode.storeAndForward) {
      return false;
    }
    for (final lane in s.lanes) {
      if (lane.id == ResilientLaneIds.txtQuery) continue;
      if (lane.eligible && lane.score > 0) return true;
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
    await lanes.fabric.refresh();
    final s = lanes.fabric.snapshot;
    note('probe mode=${s.mode.name} best=${s.bestLaneId} ${_scores(s)}');
    if (!_liveCallReachable(s)) {
      _set(
        LetterState.liveCallUnavailable,
        lanes.valve == null ? 'and no door in this build' : _scores(s),
      );
    }
  }

  /// Carries [payload] to one verdict. [kind] names it for the notes
  /// (typed / voice / photo). Returns the final state.
  Future<LetterState> send(Uint8List payload, {required String kind}) async {
    if (busy.value) return status.value?.state ?? LetterState.queued;
    busy.value = true;
    try {
      return await _send(payload, kind);
    } finally {
      busy.value = false;
    }
  }

  Future<LetterState> _send(Uint8List payload, String kind) async {
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
    final fabric = lanes.fabric;
    final chunks = TxtQueryWire.splitChunks(payload).length;
    _set(LetterState.queued, '${payload.length} B ($kind) · probing the door');

    // Select: refresh until some lane ranks first with a positive score.
    // A live lane wins as soon as it does; on the rig the two dead WAN
    // lanes score negative and the valve overtakes them after its probe.
    final selectUntil = _now().add(budget.select);
    var refreshes = 0;
    ConnectivitySnapshot s;
    while (true) {
      await fabric.refresh();
      refreshes++;
      s = fabric.snapshot;
      if (_bestIsUsable(s) || !_now().isBefore(selectUntil)) break;
      await Future<void>.delayed(budget.refreshEvery);
    }
    if (!_liveCallReachable(s)) {
      _set(LetterState.liveCallUnavailable, _scores(s));
    }
    final best = s.bestLaneId;
    note('selected best=$best refreshes=$refreshes ${_scores(s)}');
    _set(
      LetterState.queued,
      '${payload.length} B · $chunks chunks · '
      '${best == null ? 'no lane ranks yet' : 'via ${best.replaceFirst('resilient.', '')}'}',
    );

    // Carry, bounded.
    final DeliveryOutcome outcome;
    try {
      outcome = await fabric
          .deliver(
            payload,
            bundleId: 'letter-${_now().millisecondsSinceEpoch}',
            priority: LinkMessagePriority.callSignal,
          )
          .timeout(budget.carry);
    } on TimeoutException {
      _set(
        LetterState.notDelivered,
        'gave up after ${budget.carry.inSeconds}s · ${_scores(fabric.snapshot)}',
      );
      return LetterState.notDelivered;
    } on Object catch (error) {
      _set(LetterState.notDelivered, 'error: $error');
      return LetterState.notDelivered;
    }
    final valve = lanes.valve;
    final session = valve?.lastSessionId;
    note('carried outcome=${outcome.name} session=$session');
    switch (outcome) {
      case DeliveryOutcome.sentLive:
        _set(
          LetterState.arrived,
          best == ResilientLaneIds.txtQuery && session != null
              ? '${payload.length} B · through the door · session $session'
              : '${payload.length} B · via ${(best ?? 'a lane').replaceFirst('resilient.', '')}',
        );
        return LetterState.arrived;
      case DeliveryOutcome.queuedForLater:
        _set(
          LetterState.queued,
          '${payload.length} B · door down · parked in the queue',
        );
        return LetterState.queued;
      case DeliveryOutcome.rejected:
        _set(LetterState.notDelivered, 'refused by the queue');
        return LetterState.notDelivered;
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    final lanes = _lanes;
    _lanes = null;
    await lanes?.dispose();
    status.dispose();
    notes.dispose();
    busy.dispose();
  }
}
