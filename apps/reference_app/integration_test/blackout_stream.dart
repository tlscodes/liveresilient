/// The blackout v3 stream lane, phone side: pure Dart, no dart:io, so the
/// wire can be tested against a fake hub built from two stream controllers.
///
/// One framed TCP connection per probe answer. The phone sends a hello
/// naming the pending bundle ids in delivery order; the hub answers with a
/// state line that carries the lane parameters (piece size, ack cadence,
/// inflight cap, stall timeout) and how much of each id it already holds.
/// The phone then writes, per record, a header line followed by the raw
/// payload bytes from the hub's offset, in pieces of `piece_bytes`, never
/// letting more than `inflight_bytes` ride unacknowledged. The next record's
/// header goes out as soon as the previous record's bytes are written; the
/// phone does not wait for its `done`. A `done` line, whatever its
/// `sig_ok`, is the only thing that reports a record through [onDone]; the
/// caller removes it from its queue there. Any hub line resets the stall
/// timer; an `error` line, a stall, or the hub closing ends the session and
/// the lane destroys the link.
///
/// Wire (newline-delimited JSON lines; only the phone→hub direction carries
/// raw bytes):
/// ```
/// phone→hub  {"v":3,"run":"<run>","pubkey":"<b64>","ids":["<id>",...]}\n
/// hub→phone  {"state":{"<id>":{"have":<int>,"complete":<bool>},...},
///             "piece_bytes":8192,"ack_bytes":8192,"ack_interval_s":2,
///             "inflight_bytes":32768,"stall_s":15}\n
/// phone→hub  {"id":"<id>","off":<have>,"len":<total-have>,"total":<total>,
///             "created_ms":<int>,"sig":"<b64>"}\n + exactly len raw bytes
/// hub→phone  {"ack":"<id>","have":<int>}\n
/// hub→phone  {"done":"<id>","sig_ok":<bool>,"pubkey_match":<bool>,"bytes":<total>}\n
/// hub→phone  {"error":"<code>","id":<id|null>,"have":<int|null>}\n  then close
/// ```
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:device_link/device_link.dart' show DtnBundle;

/// Seconds the phone waits for the hub's state line after its hello. The
/// hub is the single source of every other lane parameter; this is the one
/// number the phone owns because no hub line has arrived yet to carry it.
const int helloTimeoutS = 20;

/// The `"v"` of the hello line.
const int streamWireV = 3;

/// The hub reads at most this many ids from one hello (journey_hub.py's
/// hello limit). A longer pending list is offered in slices: this session
/// takes the first [helloMaxIds] in delivery order, the next probe the rest.
const int helloMaxIds = 4096;

/// The lane parameters: the port from the plan's `"stream"` map, the rest
/// from the hub's state line.
class BlackoutStreamParams {
  const BlackoutStreamParams({
    required this.port,
    required this.pieceBytes,
    required this.ackBytes,
    required this.ackIntervalS,
    required this.inflightBytes,
    required this.stallS,
  });

  final int port;
  final int pieceBytes;
  final int ackBytes;
  final int ackIntervalS;
  final int inflightBytes;
  final int stallS;

  /// The `"port"` of a v3 plan's `"stream"` map; null when absent or not
  /// a valid TCP port.
  static int? portOf(Map<String, Object?>? stream) {
    final port = stream?['port'];
    return port is int && port > 0 && port < 65536 ? port : null;
  }

  /// Parsed from the hub's state line. Null when any of the five
  /// parameters is missing or not a positive int: the phone carries no
  /// defaults to fall back on, so a hub that omits one ends the session
  /// with a `bad_state` outcome.
  static BlackoutStreamParams? fromState(
    Map<String, Object?> state, {
    required int port,
  }) {
    final pieceBytes = _positiveInt(state['piece_bytes']);
    final ackBytes = _positiveInt(state['ack_bytes']);
    final ackIntervalS = _positiveInt(state['ack_interval_s']);
    final inflightBytes = _positiveInt(state['inflight_bytes']);
    final stallS = _positiveInt(state['stall_s']);
    if (pieceBytes == null ||
        ackBytes == null ||
        ackIntervalS == null ||
        inflightBytes == null ||
        stallS == null) {
      return null;
    }
    return BlackoutStreamParams(
      port: port,
      pieceBytes: pieceBytes,
      ackBytes: ackBytes,
      ackIntervalS: ackIntervalS,
      inflightBytes: inflightBytes,
      stallS: stallS,
    );
  }

  static int? _positiveInt(Object? value) =>
      value is int && value > 0 ? value : null;

  /// The same keys the hub's state line uses, plus `port`, for the peer's
  /// report notes.
  Map<String, Object?> toJson() => {
    'port': port,
    'piece_bytes': pieceBytes,
    'ack_bytes': ackBytes,
    'ack_interval_s': ackIntervalS,
    'inflight_bytes': inflightBytes,
    'stall_s': stallS,
  };
}

/// One queued bundle decoded from its v2 JSON envelope: the raw payload
/// the lane streams, and the signature and creation time the header
/// carries so the hub can verify without the envelope.
class StreamRecord {
  StreamRecord({
    required this.id,
    required this.createdMs,
    required this.sig,
    required this.payload,
  });

  final String id;
  final int createdMs;
  final List<int> sig;
  final List<int> payload;

  int get total => payload.length;

  /// Decodes the envelope buildBlackoutEnvelope wrote: keys `id`,
  /// `created_ms`, `payload` (base64) and `sig` (base64). Throws
  /// [FormatException] on anything else.
  static StreamRecord fromEnvelope(List<int> envelope) {
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(envelope));
    } on FormatException catch (e) {
      throw FormatException('envelope is not JSON: ${e.message}');
    }
    if (decoded is! Map) throw const FormatException('envelope is not a map');
    final id = decoded['id'];
    final createdMs = decoded['created_ms'];
    final payloadB64 = decoded['payload'];
    final sigB64 = decoded['sig'];
    if (id is! String || id.isEmpty) {
      throw const FormatException('envelope id missing');
    }
    if (createdMs is! int) {
      throw const FormatException('envelope created_ms missing');
    }
    if (payloadB64 is! String || sigB64 is! String) {
      throw const FormatException('envelope payload/sig missing');
    }
    return StreamRecord(
      id: id,
      createdMs: createdMs,
      sig: base64Decode(sigB64),
      payload: base64Decode(payloadB64),
    );
  }
}

/// The connection the lane drives, abstracted so a test can stand in for
/// the socket. [write] is synchronous: bytes are queued in order; [inbound]
/// yields the hub's bytes and closes when the hub closes; [destroy] drops
/// the connection. The lane calls [destroy] exactly once, at the end of
/// every [BlackoutStreamLane.run], and never writes after it.
abstract class StreamLink {
  void write(List<int> bytes);
  Stream<List<int>> get inbound;
  Future<void> destroy();
}

enum StreamOutcomeKind {
  /// Every offered record got its `done` (or was already complete).
  allDone,

  /// No hub line for `stall_s` (or [helloTimeoutS] before the state line).
  stalled,

  /// The hub closed or the inbound stream failed before every record was done.
  hubClosed,

  /// An `error` line from the hub, or a phone-side protocol failure
  /// (`bad_state`, `bad_line`, `write_failed`).
  error,
}

/// How one [BlackoutStreamLane.run] ended.
class StreamOutcome {
  const StreamOutcome._(this.kind, {this.code, this.id});

  const StreamOutcome.error({required String code, String? id})
    : this._(StreamOutcomeKind.error, code: code, id: id);

  static const StreamOutcome allDone = StreamOutcome._(
    StreamOutcomeKind.allDone,
  );
  static const StreamOutcome stalled = StreamOutcome._(
    StreamOutcomeKind.stalled,
  );
  static const StreamOutcome hubClosed = StreamOutcome._(
    StreamOutcomeKind.hubClosed,
  );

  final StreamOutcomeKind kind;

  /// The hub's error code (or the phone-side one) when [kind] is error.
  final String? code;

  /// The record the error names, when the hub named one.
  final String? id;

  bool get isAllDone => kind == StreamOutcomeKind.allDone;

  @override
  String toString() => switch (kind) {
    StreamOutcomeKind.error => 'error($code${id == null ? '' : ', $id'})',
    _ => kind.name,
  };
}

/// Per-record session state: absolute offsets on the record's payload.
class _Slot {
  _Slot(this.record);

  final StreamRecord record;

  /// Header written for this session.
  bool headerSent = false;

  /// Bytes of the payload the hub holds or has been sent: the offset the
  /// next piece starts at.
  int sent = 0;

  /// Bytes the hub has acknowledged (starts at the state line's `have`).
  int acked = 0;

  bool done = false;

  int get remaining => record.total - sent;
}

/// Drives one stream session over a [StreamLink]. One instance per [run].
class BlackoutStreamLane {
  BlackoutStreamLane({this.port = 0, this.log});

  /// The port the link was connected to; reported in [params].
  final int port;
  final void Function(String line)? log;

  /// Payload bytes written this session (headers and hello excluded, so
  /// [bytesWritten] - [bytesAcked] is the inflight amount the cap bounds).
  int bytesWritten = 0;

  /// Payload bytes the hub acknowledged this session, by `ack` and `done`
  /// lines, counted from the offset the state line gave.
  int bytesAcked = 0;

  /// `done` lines received plus records the state line marked complete.
  int doneCount = 0;

  /// Records offered in the hello (after slicing at [helloMaxIds]).
  int recordsOffered = 0;

  /// Pending bundles whose envelope did not decode; left in the queue.
  int recordsSkipped = 0;

  /// The lane parameters once the hub's state line arrived; null before.
  BlackoutStreamParams? params;

  final List<_Slot> _slots = <_Slot>[];
  final Map<String, _Slot> _byId = <String, _Slot>{};
  final List<int> _lineBuf = <int>[];
  final Completer<StreamOutcome> _finished = Completer<StreamOutcome>();
  StreamLink? _link;
  StreamSubscription<List<int>>? _sub;
  Timer? _stall;
  int _sendIdx = 0;
  bool _ran = false;

  bool get _isFinished => _finished.isCompleted;

  /// Streams [pending] (delivery order) to the hub over [link]. Calls
  /// [onDone] once per record the hub reports done, in the hub's order,
  /// including `sig_ok` false (the row fails on the hub's verdict; the
  /// phone still stops carrying the bundle). Records the state line marks
  /// complete report through [onDone] at once, with sigOk and pubkeyMatch
  /// true: the hub recorded its verdict when it completed them and holds
  /// it in its event log. Resolves when the session ends; [link] is
  /// destroyed before it resolves, on every path.
  Future<StreamOutcome> run({
    required String run,
    required String pubkeyB64,
    required List<DtnBundle> pending,
    required StreamLink link,
    required void Function(String id, bool sigOk, bool pubkeyMatch) onDone,
  }) async {
    if (_ran) throw StateError('BlackoutStreamLane.run is single-use');
    _ran = true;
    _link = link;
    _onDone = onDone;
    for (final bundle in pending) {
      if (_slots.length >= helloMaxIds) break;
      try {
        final slot = _Slot(StreamRecord.fromEnvelope(bundle.payload));
        _slots.add(slot);
        _byId[slot.record.id] = slot;
      } on FormatException catch (e) {
        recordsSkipped++;
        log?.call('stream: bundle ${bundle.id} skipped: ${e.message}');
      }
    }
    recordsOffered = _slots.length;
    if (_slots.isEmpty) {
      _finish(StreamOutcome.allDone);
    } else {
      _sub = link.inbound.listen(
        _onBytes,
        onError: (Object e) {
          log?.call('stream: inbound failed: $e');
          _finish(StreamOutcome.hubClosed);
        },
        onDone: () => _finish(StreamOutcome.hubClosed),
      );
      _writeLine({
        'v': streamWireV,
        'run': run,
        'pubkey': pubkeyB64,
        'ids': [for (final slot in _slots) slot.record.id],
      });
      _armStall(helloTimeoutS);
    }
    final outcome = await _finished.future;
    try {
      await link.destroy();
    } catch (e) {
      log?.call('stream: destroy failed: $e');
    }
    return outcome;
  }

  late void Function(String id, bool sigOk, bool pubkeyMatch) _onDone;

  // ---- inbound -----------------------------------------------------------

  void _onBytes(List<int> chunk) {
    if (_isFinished) return;
    _lineBuf.addAll(chunk);
    while (!_isFinished) {
      final nl = _lineBuf.indexOf(0x0a);
      if (nl < 0) return;
      final line = _lineBuf.sublist(0, nl);
      _lineBuf.removeRange(0, nl + 1);
      _onLine(line);
    }
  }

  void _onLine(List<int> raw) {
    // Any hub line, whatever it says, proves the hub is alive.
    _armStall(params?.stallS ?? helloTimeoutS);
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(raw));
    } on FormatException {
      _fail('bad_line');
      return;
    }
    if (decoded is! Map) {
      _fail('bad_line');
      return;
    }
    final msg = decoded.cast<String, Object?>();
    if (msg.containsKey('state')) {
      _onState(msg);
    } else if (msg.containsKey('ack')) {
      _onAck(msg);
    } else if (msg.containsKey('done')) {
      _onDoneLine(msg);
    } else if (msg.containsKey('error')) {
      final code = msg['error'];
      final id = msg['id'];
      log?.call('stream: hub error $code id=$id have=${msg['have']}');
      _finish(
        StreamOutcome.error(
          code: code is String ? code : 'unknown',
          id: id is String ? id : null,
        ),
      );
    } else {
      log?.call('stream: ignoring hub line ${msg.keys.join(',')}');
    }
  }

  void _onState(Map<String, Object?> msg) {
    if (params != null) {
      _fail('bad_line');
      return;
    }
    final parsed = BlackoutStreamParams.fromState(msg, port: port);
    final state = msg['state'];
    if (parsed == null || state is! Map) {
      _fail('bad_state');
      return;
    }
    params = parsed;
    _armStall(parsed.stallS);
    for (final slot in _slots) {
      final entry = state[slot.record.id];
      if (entry is! Map) continue;
      final have = entry['have'];
      final complete = entry['complete'] == true;
      if (complete) {
        slot.sent = slot.record.total;
        slot.acked = slot.record.total;
        slot.headerSent = true;
        _markDone(slot, sigOk: true, pubkeyMatch: true);
        if (_isFinished) return;
        continue;
      }
      if (have is int && have > 0) {
        final offset = min(have, slot.record.total);
        slot.sent = offset;
        slot.acked = offset;
      }
    }
    if (_slots.every((slot) => slot.done)) {
      _finish(StreamOutcome.allDone);
      return;
    }
    _pump();
  }

  void _onAck(Map<String, Object?> msg) {
    final id = msg['ack'];
    final have = msg['have'];
    if (id is! String || have is! int) {
      _fail('bad_line');
      return;
    }
    final slot = _byId[id];
    if (slot == null) {
      log?.call('stream: ack for unknown id $id');
      return;
    }
    _credit(slot, have);
    _pump();
  }

  void _onDoneLine(Map<String, Object?> msg) {
    final id = msg['done'];
    if (id is! String) {
      _fail('bad_line');
      return;
    }
    final slot = _byId[id];
    if (slot == null) {
      log?.call('stream: done for unknown id $id');
      return;
    }
    if (slot.done) return;
    _credit(slot, slot.record.total);
    _markDone(
      slot,
      sigOk: msg['sig_ok'] == true,
      pubkeyMatch: msg['pubkey_match'] == true,
    );
    if (_isFinished) return;
    if (_slots.every((s) => s.done)) {
      _finish(StreamOutcome.allDone);
      return;
    }
    _pump();
  }

  /// Moves [slot]'s acknowledged mark up to [have], never past what was
  /// written (a hub claiming more than it was sent would otherwise open
  /// the inflight cap).
  void _credit(_Slot slot, int have) {
    final bounded = min(have, slot.sent);
    if (bounded <= slot.acked) return;
    bytesAcked += bounded - slot.acked;
    slot.acked = bounded;
  }

  void _markDone(_Slot slot, {required bool sigOk, required bool pubkeyMatch}) {
    slot.done = true;
    doneCount++;
    log?.call(
      'stream: done ${slot.record.id} ${slot.record.total} B '
      'sig_ok=$sigOk pubkey_match=$pubkeyMatch',
    );
    _onDone(slot.record.id, sigOk, pubkeyMatch);
  }

  // ---- outbound ----------------------------------------------------------

  /// Writes what the cap allows: the current record's next pieces, then
  /// the next record's header and its pieces, until the inflight amount
  /// reaches `inflight_bytes` or nothing is left to write.
  void _pump() {
    final p = params;
    if (p == null) return;
    while (!_isFinished) {
      final slot = _nextToSend();
      if (slot == null) return;
      if (!slot.headerSent) {
        slot.headerSent = true;
        _writeLine({
          'id': slot.record.id,
          'off': slot.sent,
          'len': slot.remaining,
          'total': slot.record.total,
          'created_ms': slot.record.createdMs,
          'sig': base64Encode(slot.record.sig),
        });
        continue;
      }
      final inflight = bytesWritten - bytesAcked;
      if (inflight >= p.inflightBytes) return;
      final n = min(
        p.pieceBytes,
        min(slot.remaining, p.inflightBytes - inflight),
      );
      if (n <= 0) return;
      _write(slot.record.payload.sublist(slot.sent, slot.sent + n));
      if (_isFinished) return;
      slot.sent += n;
      bytesWritten += n;
    }
  }

  /// The first record that still has a header or bytes to write.
  _Slot? _nextToSend() {
    while (_sendIdx < _slots.length) {
      final slot = _slots[_sendIdx];
      if (!slot.done && (!slot.headerSent || slot.remaining > 0)) return slot;
      _sendIdx++;
    }
    return null;
  }

  void _writeLine(Map<String, Object?> line) =>
      _write(utf8.encode('${jsonEncode(line)}\n'));

  void _write(List<int> bytes) {
    if (_isFinished) return;
    try {
      _link!.write(bytes);
    } catch (e) {
      log?.call('stream: write failed: $e');
      _fail('write_failed');
    }
  }

  // ---- session end -------------------------------------------------------

  void _armStall(int seconds) {
    _stall?.cancel();
    _stall = Timer(Duration(seconds: seconds), () {
      log?.call('stream: no hub line for $seconds s');
      _finish(StreamOutcome.stalled);
    });
  }

  void _fail(String code) => _finish(StreamOutcome.error(code: code));

  /// Ends the session once: stops the stall timer, drops the inbound
  /// subscription without awaiting its cancel future (that future is
  /// completed in the root zone, so awaiting it would park a fake-async
  /// test), and resolves [run], which then destroys the link.
  void _finish(StreamOutcome outcome) {
    if (_isFinished) return;
    _stall?.cancel();
    _stall = null;
    final sub = _sub;
    _sub = null;
    if (sub != null) unawaited(sub.cancel());
    _finished.complete(outcome);
  }
}
