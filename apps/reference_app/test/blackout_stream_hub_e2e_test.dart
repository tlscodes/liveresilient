/// The blackout v3 stream lane end to end over loopback: the REAL hub
/// (tools/t2/journey_hub.py, HTTP on 8811, stream lane on 8812) driven by
/// the phone-side [BlackoutStreamLane] over a real dart:io socket, with the
/// Gate 2 plan (60 bundles, 1,234,800 B) held in a [DtnBundleQueue].
///
/// Run 1 cuts the socket once the hub has acknowledged 150,000 B (a
/// simulated outage): the outcome must not be allDone. Run 2 opens a new
/// socket, resumes at the hub's offsets and must reach allDone with every
/// done acknowledged in the queue. The hub side is then read from disk: 60
/// bundle_received events with stream:true, sig_ok and pubkey_match true,
/// every blob byte-equal to its payload, stream_stats.json bytes_carried ==
/// 1,234,800 with connections == 2, and no error line in the hub's output.
///
/// Skipped with a printed reason when python3 cannot import cryptography.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:device_link/device_link.dart'
    show DtnBundle, DtnBundleQueue, InMemoryBundleStore, BundleAdmission;
import 'package:flutter_test/flutter_test.dart';

import '../integration_test/blackout_forwarder.dart';
import '../integration_test/blackout_stream.dart';

const int _httpPort = 8811;
const int _streamPort = 8812;
const String _run = 'e2e';

/// Run 1 is cut on the first write after the hub has acknowledged this
/// many payload bytes.
const int _cutAtAckedBytes = 150000;

/// The Gate 2 plan of the adopted design: 60 bundles, 1,234,800 B.
const List<({String kind, int bytes, int n})> _plan = [
  (kind: 'text', bytes: 200, n: 24),
  (kind: 'voice', bytes: 5000, n: 18),
  (kind: 'photo', bytes: 45000, n: 12),
  (kind: 'video', bytes: 100000, n: 6),
];
const int _planBundles = 60;
const int _planBytes = 1234800;

/// Lines in the hub's output that mean something went wrong on its side.
final List<RegExp> _hubErrorPatterns = [
  RegExp(r'Traceback'),
  RegExp(r'\bError\b'),
  RegExp(r'\bException\b'),
  RegExp(r'closed error'),
  RegExp(r'closed io'),
  RegExp(r'closed silent'),
  RegExp(r'preempted'),
];

/// An abortive close arriving at the hub: the peer sent a reset instead of a
/// clean shutdown. Errno 54 is ECONNRESET on macOS, 104 on Linux; 32 is EPIPE
/// on a hub write that raced the reset.
final RegExp _abortiveClose = RegExp(
  r'closed io \[Errno (54|104|32)\]|'
  r'closed io .*(Connection reset by peer|Broken pipe)',
);

/// cwd for this suite is apps/reference_app.
String get _repoRoot => Directory.current.parent.parent.path;

/// The hub under test as a child process, its output collected per line.
class _HubProcess {
  _HubProcess._(this.process, this.runDir);

  final Process process;
  final Directory runDir;
  final List<String> log = <String>[];

  static Future<_HubProcess> start(Directory runDir) async {
    File(
      '${runDir.path}/job.json',
    ).writeAsStringSync(jsonEncode({'run': _run}));
    final process = await Process.start('python3', [
      '$_repoRoot/tools/t2/journey_hub.py',
      '--bind',
      '127.0.0.1',
      '--port',
      '$_httpPort',
      '--dir',
      runDir.path,
      '--stream-port',
      '$_streamPort',
    ]);
    final hub = _HubProcess._(process, runDir);
    for (final stream in [process.stdout, process.stderr]) {
      stream
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(hub.log.add);
    }
    for (final port in [_httpPort, _streamPort]) {
      await hub._awaitPort(port);
    }
    return hub;
  }

  Future<void> _awaitPort(int port) async {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (true) {
      try {
        final probe = await Socket.connect(
          '127.0.0.1',
          port,
          timeout: const Duration(milliseconds: 500),
        );
        probe.destroy();
        return;
      } on SocketException {
        if (DateTime.now().isAfter(deadline)) {
          throw StateError(
            'hub port $port never came up; hub output:\n${log.join('\n')}',
          );
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  }

  /// Waits until the hub has logged [n] stream connection closes, so the
  /// close-time stats write and log lines are on disk before assertions.
  Future<void> awaitStreamCloses(int n) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (closedCount < n) {
      if (DateTime.now().isAfter(deadline)) {
        throw StateError(
          'hub logged $closedCount stream closes, wanted $n:\n${log.join('\n')}',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  int get closedCount => log
      .where((l) => l.startsWith('hub stream ') && l.contains(' closed '))
      .length;

  List<String> get errorLines =>
      log.where((l) => _hubErrorPatterns.any((p) => p.hasMatch(l))).toList();

  /// Error lines the hub raised on its own behalf.
  ///
  /// The cut connection's reset is not one of them. Run 1 calls
  /// `Socket.destroy()` on purpose, and an abortive close reaches the hub as
  /// ECONNRESET or as EOF depending on whether unread acknowledgement bytes
  /// were sitting in the receive buffer at that instant — a kernel-level race
  /// this test cannot and should not control. Measured before this was
  /// separated out: two failures in three consecutive local runs, every one of
  /// them with all sixty bundles delivered, hash-verified and accounted for.
  /// The assertion was failing on the artifact of its own scenario.
  ///
  /// Every other error line still fails the gate, including an abortive close
  /// on the resumed connection or on the hub's own probe connections, none of
  /// which this test causes. [cutPeer] is the cut link's own address, taken
  /// from the socket rather than guessed from the log: the hub accepts an
  /// earlier short-lived stream connection before this one, so "the first
  /// stream peer in the log" is not the connection that gets cut.
  List<String> unexpectedErrorLines(String cutPeer) => errorLines
      .where((l) => !(l.contains(' $cutPeer ') && _abortiveClose.hasMatch(l)))
      .toList();

  Future<int> stop() async {
    process.kill();
    return process.exitCode;
  }
}

/// POST /report with the boot event that registers the test key, exactly
/// as the peer app does at boot (and tools/t2/test_journey_hub_stream.py).
Future<int> _postBoot(String pubkeyB64) async {
  final client = HttpClient();
  try {
    final req = await client.postUrl(
      Uri.parse('http://127.0.0.1:$_httpPort/report'),
    );
    req.headers.contentType = ContentType.json;
    req.write(
      jsonEncode({
        'event': 'boot',
        'run': null,
        'at': 't',
        'pubkey': pubkeyB64,
      }),
    );
    final res = await req.close();
    await res.drain<void>();
    return res.statusCode;
  } finally {
    client.close(force: true);
  }
}

/// The socket link of journey_peer_app.dart, re-implemented here with one
/// addition: [cutWhen], checked before every write, destroys the socket
/// the first time it returns true and drops that and every later write.
class _SocketLink implements StreamLink {
  _SocketLink(this._socket, {this.cutWhen}) {
    // Read now, not lazily: once the socket is destroyed the port is gone, and
    // the cut is exactly when this value is needed.
    peer = '${_socket.address.address}:${_socket.port}';
    _socket.done.then<void>((_) {}, onError: (Object _) {});
  }

  /// This link's local address as the hub prints it in its log, which is how
  /// the assertions name the one connection this test cuts on purpose.
  late final String peer;

  final Socket _socket;
  final bool Function()? cutWhen;
  bool cut = false;

  @override
  void write(List<int> bytes) {
    if (!cut && (cutWhen?.call() ?? false)) {
      cut = true;
      _socket.destroy();
    }
    if (cut) return;
    _socket.add(bytes);
  }

  @override
  Stream<List<int>> get inbound => _socket;

  @override
  Future<void> destroy() async => _socket.destroy();
}

class _Done {
  const _Done(this.id, this.sigOk, this.pubkeyMatch);
  final String id;
  final bool sigOk;
  final bool pubkeyMatch;
}

/// One lane session over a fresh loopback socket.
Future<({StreamOutcome outcome, BlackoutStreamLane lane, _SocketLink link})>
_session({
  required DtnBundleQueue queue,
  required String pubkeyB64,
  required List<_Done> dones,
  required int nowMs,
  bool Function(BlackoutStreamLane lane)? cutWhen,
}) async {
  final socket = await Socket.connect(
    '127.0.0.1',
    _streamPort,
    timeout: const Duration(seconds: 10),
  );
  final lane = BlackoutStreamLane(port: _streamPort);
  final link = _SocketLink(
    socket,
    cutWhen: cutWhen == null ? null : () => cutWhen(lane),
  );
  final outcome = await lane.run(
    run: _run,
    pubkeyB64: pubkeyB64,
    pending: queue.pendingInDeliveryOrder(nowMs),
    link: link,
    onDone: (id, sigOk, pubkeyMatch) {
      dones.add(_Done(id, sigOk, pubkeyMatch));
      expect(queue.acknowledge(id), isTrue, reason: 'done for $id not queued');
    },
  );
  return (outcome: outcome, lane: lane, link: link);
}

Future<bool> _pythonHasCryptography() async {
  try {
    final r = await Process.run('python3', ['-c', 'import cryptography']);
    return r.exitCode == 0;
  } on ProcessException {
    return false;
  }
}

void main() {
  late Directory runDir;
  _HubProcess? hub;

  setUp(() {
    runDir = Directory.systemTemp.createTempSync('blackout_stream_e2e.');
  });

  tearDown(() async {
    final h = hub;
    hub = null;
    if (h != null) await h.stop();
    if (runDir.existsSync()) runDir.deleteSync(recursive: true);
  });

  test(
    'Gate 2 plan over loopback: cut at 150 KB acked, resume, 60/60 on the hub',
    () async {
      if (!await _pythonHasCryptography()) {
        const reason = 'python3 cannot import cryptography; hub cannot verify';
        // ignore: avoid_print
        print('SKIP: $reason');
        markTestSkipped(reason);
        return;
      }
      hub = await _HubProcess.start(runDir);

      // The same signing path the peer app uses for every bundle.
      final ed25519 = Ed25519();
      final keyPair = await ed25519.newKeyPair();
      final pubkeyB64 = base64Encode((await keyPair.extractPublicKey()).bytes);
      expect(await _postBoot(pubkeyB64), 200);

      // 60 bundles in a queue, the raw payload kept per id for the blob check.
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final queue = DtnBundleQueue(store: InMemoryBundleStore());
      final payloads = <String, List<int>>{};
      final random = Random(20260905);
      var planned = 0;
      for (final entry in _plan) {
        for (var seq = 1; seq <= entry.n; seq++) {
          final item = BlackoutPlanItem(
            kind: entry.kind,
            bytes: entry.bytes,
            seq: seq,
          );
          final createdMs = nowMs - 60000 + planned;
          final payload = blackoutPayload(
            run: _run,
            item: item,
            createdMs: createdMs,
            random: random,
          );
          final id = '${entry.kind}-${seq.toString().padLeft(2, '0')}';
          final signature = await ed25519.sign(payload, keyPair: keyPair);
          final bundle = DtnBundle(
            id: id,
            payload: buildBlackoutEnvelope(
              run: _run,
              id: id,
              createdMs: createdMs,
              payload: payload,
              signature: signature.bytes,
              pubkeyB64: pubkeyB64,
            ),
            priority: item.priority,
            createdAtMs: createdMs,
            lifetimeMs: 6 * 3600 * 1000,
          );
          expect(queue.offer(bundle, nowMs: nowMs), BundleAdmission.stored);
          payloads[id] = payload;
          planned++;
        }
      }
      expect(planned, _planBundles);
      expect(payloads.values.fold<int>(0, (s, p) => s + p.length), _planBytes);

      final dones = <_Done>[];

      // Run 1: the outage. Cut on the first write after 150,000 B acked.
      final run1 = await _session(
        queue: queue,
        pubkeyB64: pubkeyB64,
        dones: dones,
        nowMs: nowMs,
        cutWhen: (lane) => lane.bytesAcked >= _cutAtAckedBytes,
      );
      expect(run1.link.cut, isTrue, reason: 'the cut never fired');
      expect(run1.outcome.isAllDone, isFalse, reason: '${run1.outcome}');
      expect(run1.lane.bytesAcked, greaterThanOrEqualTo(_cutAtAckedBytes));
      expect(queue.pendingCount, greaterThan(0));
      // Let the hub's handler see the EOF before the next hello, so run 2
      // resumes into a closed session rather than preempting a live one.
      await hub!.awaitStreamCloses(1);

      // Run 2: resume on a new socket to allDone.
      final wall = Stopwatch()..start();
      final run2 = await _session(
        queue: queue,
        pubkeyB64: pubkeyB64,
        dones: dones,
        nowMs: nowMs,
      );
      wall.stop();
      expect(run2.outcome.isAllDone, isTrue, reason: '${run2.outcome}');
      expect(run2.link.cut, isFalse);
      expect(queue.pendingCount, 0, reason: 'every done acknowledged');
      expect(queue.pendingBytes, 0);
      expect(dones.map((d) => d.id).toSet(), payloads.keys.toSet());
      expect(dones.length, _planBundles, reason: 'one done per bundle');
      expect(dones.every((d) => d.sigOk && d.pubkeyMatch), isTrue);
      expect(run1.lane.doneCount + run2.lane.doneCount, _planBundles);
      expect(run2.lane.recordsSkipped, 0);

      final run2Seconds = wall.elapsedMicroseconds / 1e6;
      final run2Rate = run2.lane.bytesWritten / run2Seconds;
      // ignore: avoid_print
      print(
        'run1 outcome=${run1.outcome} written=${run1.lane.bytesWritten} '
        'acked=${run1.lane.bytesAcked} done=${run1.lane.doneCount}; '
        'run2 outcome=${run2.outcome} written=${run2.lane.bytesWritten} '
        'acked=${run2.lane.bytesAcked} done=${run2.lane.doneCount} '
        'wall=${run2Seconds.toStringAsFixed(3)} s '
        'rate=${run2Rate.toStringAsFixed(0)} B/s over loopback',
      );

      // The hub side, after its second close is logged.
      await hub!.awaitStreamCloses(2);
      final eventsFile = File('${runDir.path}/phone_events.jsonl');
      expect(eventsFile.existsSync(), isTrue);
      final received = eventsFile
          .readAsLinesSync()
          .where((l) => l.trim().isNotEmpty)
          .map((l) => jsonDecode(l) as Map<String, Object?>)
          .where((e) => e['event'] == 'bundle_received')
          .toList();
      expect(received.length, _planBundles, reason: 'bundle_received events');
      expect(received.map((e) => e['id']).toSet(), payloads.keys.toSet());
      for (final e in received) {
        expect(e['stream'], isTrue, reason: '${e['id']} stream flag');
        expect(e['sig_ok'], isTrue, reason: '${e['id']} sig_ok');
        expect(e['pubkey_match'], isTrue, reason: '${e['id']} pubkey_match');
        expect(e.containsKey('chunks'), isFalse, reason: '${e['id']} chunks');
        expect(e['bytes'], payloads[e['id']]!.length, reason: '${e['id']}');
      }
      for (final entry in payloads.entries) {
        final blob = File('${runDir.path}/blobs/bundle-${entry.key}.bin');
        expect(blob.existsSync(), isTrue, reason: 'blob ${entry.key}');
        expect(
          blob.readAsBytesSync(),
          entry.value,
          reason: 'blob ${entry.key} bytes',
        );
      }
      final stats =
          jsonDecode(
                File('${runDir.path}/stream_stats.json').readAsStringSync(),
              )
              as Map<String, Object?>;
      expect(stats['bytes_carried'], _planBytes, reason: '$stats');
      expect(stats['records'], _planBundles, reason: '$stats');
      expect(stats['connections'], 2, reason: '$stats');
      expect(
        hub!.unexpectedErrorLines(run1.link.peer),
        isEmpty,
        reason: hub!.log.join('\n'),
      );
      // Only the connection run 1 destroys may close abortively, and only once.
      expect(
        hub!.errorLines.length,
        lessThanOrEqualTo(1),
        reason:
            'at most the cut connection may close abortively:\n'
            '${hub!.log.join('\n')}',
      );
    },
    timeout: const Timeout(Duration(seconds: 120)),
  );
}
