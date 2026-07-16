/// Local load/soak harness for the signaling relay (gate ladder G8).
///
/// Spins a [SignalingRelayServer] in-process over real TLS loopback sockets,
/// creates N two-party rooms, ping-pongs M frames per room with round-trip
/// timing, tears everything down, and prints one machine-readable JSON
/// summary line.
///
/// Honesty notes (bounds of what this harness can prove):
/// - This is a SINGLE-PROCESS loopback measurement: clients and server share
///   one Dart isolate and event loop, so every reported latency includes
///   client-side scheduling and is an upper bound on server-side latency.
///   The summary carries `clientBound: true` to make that explicit.
/// - G8's 10k tier is a real-infrastructure claim. A local process can only
///   report the numbers it actually achieved at the tier it actually ran —
///   this tool never claims a tier it did not complete.
///
/// Usage:
///   dart run bin/load_soak.dart --tier 100
///   dart run bin/load_soak.dart --tier 1k
///   dart run bin/load_soak.dart --rooms 500 --messages 10
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:signaling_server/signaling_server.dart';

/// Marker body of the pairing handshake frame (mirrors the relay test
/// suite's seed pattern: both peers send one seed; the buffered seed flushes
/// to the late joiner and the joiner's seed relays live to the creator).
const String _seedBody = '__seed__';

/// Prefix that tells the responder side to echo a frame back verbatim.
const String _pingPrefix = 'p:';

/// LOAD-TEST configuration — deliberately permissive, NEVER for production.
///
/// The production defaults in [AbuseControlConfig] (30 msg/s per connection,
/// 20 new callIds per source per minute, 16 concurrent rooms per source) are
/// exactly right for real deployments and exactly wrong for a loopback load
/// test, where every client shares the single source key `127.0.0.1` and
/// intentionally creates [rooms] rooms as fast as possible. This config
/// lifts those limits far above the load pattern so the harness measures
/// relay throughput, not the abuse guard tripping on its own test rig.
AbuseControlConfig loadTestAbuseControls({required int rooms}) {
  return AbuseControlConfig(
    // Ping-pong at loopback speed easily exceeds 30 msg/s per connection.
    messagesPerSecond: 1000000,
    messageBurst: 1 << 20,
    // All rooms are created by one source (127.0.0.1) inside one window.
    maxNewCallIdsPerWindow: rooms + 64,
    maxConcurrentRoomsGlobal: rooms + 64,
    maxConcurrentRoomsPerSource: rooms + 64,
    // Idle TTL stays far above the run length so the sweep never reaps a
    // live room mid-measurement; sweep cadence keeps the default.
    idleRoomTtl: const Duration(minutes: 30),
  );
}

/// Aggregated result of one load/soak run — every field is a measured
/// number, never an adjective.
class LoadSoakSummary {
  const LoadSoakSummary({
    required this.tier,
    required this.rooms,
    required this.messagesPerRoom,
    required this.elapsedMs,
    required this.setupMsP50,
    required this.setupMsP95,
    required this.rttMsP50,
    required this.rttMsP95,
    required this.framesSent,
    required this.framesDelivered,
    required this.errors,
    required this.peakActiveRooms,
    required this.activeRoomsAfterTeardown,
    required this.reapedRooms,
    required this.rssBeforeBytes,
    required this.rssAfterBytes,
  });

  final String tier;
  final int rooms;
  final int messagesPerRoom;
  final int elapsedMs;
  final double setupMsP50;
  final double setupMsP95;
  final double rttMsP50;
  final double rttMsP95;
  final int framesSent;
  final int framesDelivered;
  final int errors;
  final int peakActiveRooms;
  final int activeRoomsAfterTeardown;
  final int reapedRooms;
  final int rssBeforeBytes;
  final int rssAfterBytes;

  int get rssDeltaBytes => rssAfterBytes - rssBeforeBytes;

  Map<String, Object?> toJson() => <String, Object?>{
    'tier': tier,
    'rooms': rooms,
    'messagesPerRoom': messagesPerRoom,
    'elapsedMs': elapsedMs,
    'setupMsP50': setupMsP50,
    'setupMsP95': setupMsP95,
    'rttMsP50': rttMsP50,
    'rttMsP95': rttMsP95,
    'framesSent': framesSent,
    'framesDelivered': framesDelivered,
    'errors': errors,
    'peakActiveRooms': peakActiveRooms,
    'activeRoomsAfterTeardown': activeRoomsAfterTeardown,
    'reapedRooms': reapedRooms,
    'rssBeforeBytes': rssBeforeBytes,
    'rssAfterBytes': rssAfterBytes,
    'rssDeltaBytes': rssDeltaBytes,
    // Single-process loopback: latencies include client-side event-loop
    // scheduling (upper bound on true server latency).
    'clientBound': true,
  };
}

/// Runs the full load/soak scenario and returns the measured summary.
///
/// [setupConcurrency] bounds how many rooms are being connected/paired at
/// once (TLS handshakes are CPU-heavy); the message-exchange phase then runs
/// across ALL rooms concurrently so round-trip latency is measured under
/// full concurrent-room load.
Future<LoadSoakSummary> runLoadSoak({
  required int rooms,
  required int messagesPerRoom,
  String tier = 'custom',
  int setupConcurrency = 32,
  Duration pingTimeout = const Duration(seconds: 30),
  void Function(String message)? onProgress,
}) async {
  if (rooms < 1) throw ArgumentError.value(rooms, 'rooms', 'must be >= 1');
  if (messagesPerRoom < 1) {
    throw ArgumentError.value(
      messagesPerRoom,
      'messagesPerRoom',
      'must be >= 1',
    );
  }
  final progress = onProgress ?? (_) {};

  final certDir = await Directory.systemTemp.createTemp('load_soak_certs_');
  final wallClock = Stopwatch()..start();
  final rssBefore = ProcessInfo.currentRss;

  final certificate = await ensureDevCertificate(directoryPath: certDir.path);
  final security = SecurityContext()
    ..useCertificateChain(certificate.certificatePath)
    ..usePrivateKey(certificate.privateKeyPath);

  final server = await SignalingRelayServer.bind(
    security: security,
    abuseControls: loadTestAbuseControls(rooms: rooms),
  );

  var peakActiveRooms = 0;
  final peakSampler = Timer.periodic(const Duration(milliseconds: 50), (_) {
    peakActiveRooms = math.max(peakActiveRooms, server.activeRooms);
  });

  final roomHarnesses = <_RoomHarness>[
    for (var i = 0; i < rooms; i++)
      _RoomHarness('load-room-$i', server.port, pingTimeout),
  ];

  try {
    // Phase 1: connect + pair all rooms (bounded handshake concurrency).
    progress('setup: $rooms rooms (concurrency $setupConcurrency)');
    await _forEachPooled(
      roomHarnesses,
      setupConcurrency,
      (room) => room.setUp(),
    );
    peakActiveRooms = math.max(peakActiveRooms, server.activeRooms);

    // Phase 2: every successfully paired room ping-pongs concurrently.
    progress('exchange: $messagesPerRoom frames per room');
    await Future.wait(<Future<void>>[
      for (final room in roomHarnesses) room.exchange(messagesPerRoom),
    ]);
    peakActiveRooms = math.max(peakActiveRooms, server.activeRooms);

    // Phase 3: tear every room down and wait for the server to agree.
    progress('teardown: closing ${2 * rooms} sockets');
    await Future.wait(<Future<void>>[
      for (final room in roomHarnesses) room.tearDown(),
    ]);
    final drained = await _waitForZeroActiveRooms(server);
    if (!drained) {
      // Counted as an error: rooms outliving their sockets is a leak.
      roomHarnesses.first.errors++;
    }
  } finally {
    peakSampler.cancel();
  }

  // Let closed-socket finalizers run before sampling the final footprint.
  await Future<void>.delayed(const Duration(milliseconds: 200));
  final rssAfter = ProcessInfo.currentRss;
  final activeAfterTeardown = server.activeRooms;
  final reaped = server.counters.idleRoomsReaped;
  await server.close();
  await certDir.delete(recursive: true);
  wallClock.stop();

  final setupMicros = <int>[
    for (final room in roomHarnesses)
      if (room.setupMicros != null) room.setupMicros!,
  ];
  final rttMicros = <int>[for (final room in roomHarnesses) ...room.rttMicros];

  return LoadSoakSummary(
    tier: tier,
    rooms: rooms,
    messagesPerRoom: messagesPerRoom,
    elapsedMs: wallClock.elapsedMilliseconds,
    setupMsP50: _percentileMs(setupMicros, 50),
    setupMsP95: _percentileMs(setupMicros, 95),
    rttMsP50: _percentileMs(rttMicros, 50),
    rttMsP95: _percentileMs(rttMicros, 95),
    framesSent: roomHarnesses.fold(0, (sum, r) => sum + r.framesSent),
    framesDelivered: roomHarnesses.fold(0, (sum, r) => sum + r.framesDelivered),
    errors: roomHarnesses.fold(0, (sum, r) => sum + r.errors),
    peakActiveRooms: peakActiveRooms,
    activeRoomsAfterTeardown: activeAfterTeardown,
    reapedRooms: reaped,
    rssBeforeBytes: rssBefore,
    rssAfterBytes: rssAfter,
  );
}

/// One two-party room: `a` drives pings, `b` echoes them back verbatim.
class _RoomHarness {
  _RoomHarness(this.callId, this.port, this.pingTimeout);

  final String callId;
  final int port;
  final Duration pingTimeout;

  WebSocket? _a;
  WebSocket? _b;
  int? setupMicros;
  final List<int> rttMicros = <int>[];
  int framesSent = 0;
  int framesDelivered = 0;
  int errors = 0;

  final Completer<void> _aSawPeerSeed = Completer<void>();
  final Completer<void> _bSawPeerSeed = Completer<void>();
  Completer<String>? _pendingEcho;

  String _envelope(String body) =>
      jsonEncode(<String, Object?>{'callId': callId, 'body': body});

  Future<WebSocket> _connect() async {
    // Dedicated HttpClient per socket: the dev certificate is self-signed,
    // and per-socket clients keep this rig free of any shared connection
    // pool that could bottleneck the measurement on the client side.
    final client = HttpClient()
      ..badCertificateCallback = (cert, host, port) => true;
    return WebSocket.connect('wss://localhost:$port/', customClient: client);
  }

  /// Connects both peers and completes the seed handshake (room paired and
  /// buffer flushed both ways). Records the wall time as this room's setup.
  Future<void> setUp() async {
    final stopwatch = Stopwatch()..start();
    try {
      final a = _a = await _connect();
      a.listen((Object? raw) {
        final frame = raw is String ? raw : '';
        if (!_aSawPeerSeed.isCompleted && frame == _envelope(_seedBody)) {
          _aSawPeerSeed.complete();
          return;
        }
        final pending = _pendingEcho;
        if (pending != null && !pending.isCompleted) {
          pending.complete(frame);
        }
      }, onError: (Object _) => errors++);
      a.add(_envelope(_seedBody));

      final b = _b = await _connect();
      b.listen((Object? raw) {
        final frame = raw is String ? raw : '';
        if (!_bSawPeerSeed.isCompleted && frame == _envelope(_seedBody)) {
          _bSawPeerSeed.complete();
          return;
        }
        if (frame.contains('"$_pingPrefix')) {
          b.add(frame); // Echo verbatim -> completes a's round trip.
        }
      }, onError: (Object _) => errors++);
      b.add(_envelope(_seedBody));

      await Future.wait(<Future<void>>[
        _aSawPeerSeed.future,
        _bSawPeerSeed.future,
      ]).timeout(pingTimeout);
      setupMicros = stopwatch.elapsedMicroseconds;
    } on Object {
      errors++;
    }
  }

  /// Sequential ping-pong: each round trip is
  /// a -> server -> b -> server -> a, timed individually.
  Future<void> exchange(int messages) async {
    if (setupMicros == null) return; // Setup failed; already counted.
    for (var i = 0; i < messages; i++) {
      final frame = _envelope('$_pingPrefix$i');
      final pending = _pendingEcho = Completer<String>();
      final stopwatch = Stopwatch()..start();
      framesSent++;
      _a!.add(frame);
      try {
        final echoed = await pending.future.timeout(pingTimeout);
        if (echoed == frame) {
          rttMicros.add(stopwatch.elapsedMicroseconds);
          framesDelivered++;
        } else {
          errors++;
        }
      } on TimeoutException {
        errors++;
      }
    }
    _pendingEcho = null;
  }

  Future<void> tearDown() async {
    try {
      await Future.wait(<Future<void>>[
        if (_a != null) _a!.close(),
        if (_b != null) _b!.close(),
      ]);
    } on Object {
      errors++;
    }
  }
}

/// Runs [action] over [items] with at most [width] in flight at once.
Future<void> _forEachPooled<T>(
  List<T> items,
  int width,
  Future<void> Function(T item) action,
) async {
  var next = 0;
  Future<void> worker() async {
    while (true) {
      final index = next++;
      if (index >= items.length) return;
      await action(items[index]);
    }
  }

  await Future.wait(<Future<void>>[
    for (var i = 0; i < math.min(width, items.length); i++) worker(),
  ]);
}

/// Polls until the server tracks zero rooms (sockets fully unwound) or
/// [timeout] elapses. Returns whether it drained.
Future<bool> _waitForZeroActiveRooms(
  SignalingRelayServer server, {
  Duration timeout = const Duration(seconds: 15),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (server.activeRooms > 0) {
    if (DateTime.now().isAfter(deadline)) return false;
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  return true;
}

double _percentileMs(List<int> micros, int percentile) {
  if (micros.isEmpty) return 0;
  final sorted = List<int>.of(micros)..sort();
  final rank = (percentile / 100 * sorted.length).ceil() - 1;
  final index = rank.clamp(0, sorted.length - 1);
  return sorted[index] / Duration.microsecondsPerMillisecond;
}

const Map<String, ({int rooms, int messages})> _tierPresets =
    <String, ({int rooms, int messages})>{
      '100': (rooms: 100, messages: 20),
      '1k': (rooms: 1000, messages: 10),
    };

Future<void> main(List<String> arguments) async {
  int? rooms;
  int? messages;
  var tier = 'custom';

  for (var i = 0; i < arguments.length; i++) {
    final arg = arguments[i];
    String flag;
    String? value;
    final eq = arg.indexOf('=');
    if (arg.startsWith('--') && eq != -1) {
      flag = arg.substring(0, eq);
      value = arg.substring(eq + 1);
    } else {
      flag = arg;
      if (i + 1 < arguments.length) {
        value = arguments[i + 1];
        i++;
      }
    }
    switch (flag) {
      case '--rooms':
        if (value != null) rooms = int.parse(value);
      case '--messages':
        if (value != null) messages = int.parse(value);
      case '--tier':
        if (value != null) tier = value;
      default:
        stderr.writeln('unknown argument: $flag');
        exitCode = 2;
        return;
    }
  }

  final preset = _tierPresets[tier];
  if (preset == null && tier != 'custom') {
    stderr.writeln(
      'unknown tier "$tier" (known: ${_tierPresets.keys.join(', ')}); '
      'use --rooms/--messages for a custom run',
    );
    exitCode = 2;
    return;
  }
  final resolvedRooms = rooms ?? preset?.rooms;
  final resolvedMessages = messages ?? preset?.messages ?? 10;
  if (resolvedRooms == null) {
    stderr.writeln('missing --tier (100|1k) or --rooms N');
    exitCode = 2;
    return;
  }

  final summary = await runLoadSoak(
    rooms: resolvedRooms,
    messagesPerRoom: resolvedMessages,
    tier: tier,
    onProgress: (message) => stderr.writeln('[load_soak] $message'),
  );
  stdout.writeln(jsonEncode(summary.toJson()));
  if (summary.errors > 0) exitCode = 1;
}
