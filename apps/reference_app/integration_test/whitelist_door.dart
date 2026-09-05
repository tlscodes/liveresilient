/// The whitelist profile's phone-side evidence loop: pure Dart, no dart:io,
/// so every branch is testable against fakes with no network and no waiting.
///
/// Three things run here, and all three must hold for the profile's row to
/// be PASS:
///
///  1. The ordinary-traffic loop. One plain HTTPS GET of the allowed host
///     per interval. The FIRST 2xx stamps [DoorOpen] once — the moment the
///     door was measured open — and the loop keeps running for the whole
///     job so the stamp is not a single lucky second: [ok] and [fail] carry
///     the totals into the `ended` report.
///  2. The reset negative control. A TCP connect to a NON-allowed host on
///     the RST port must come back RESET, and fast. A connect that TIMES
///     OUT is a FAILURE of this control, not a pass: a timeout means the
///     packet was dropped somewhere, which does not prove the filter's
///     `block return-rst` rule fired. The two are different outcomes and
///     the report carries which one happened.
///  3. The QUIC negative control. One QUIC-shaped UDP datagram to the same
///     host must get nothing back. Silence is the PASS case here; any reply
///     means UDP left the phone and came back, which the filter forbids.
///
/// Every side effect is an injected seam — [DoorHttpGetter], [DoorTcpConnector],
/// [DoorUdpProber], [DoorClock] — because the peer app that owns the real
/// sockets has no test seam of its own (same reason `blackout_stream.dart`
/// is shaped this way).
library;

import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

/// One QUIC Initial packet's worth of bytes: a long header with version 1
/// and two random 8-byte connection ids, padded to 1200 bytes.
///
/// RFC 9000 §14.1 requires a client's Initial datagram to be at least 1200
/// bytes, so this is the shape a real QUIC handshake puts on the wire —
/// which is the point: the control must send what the filter is meant to
/// drop, not an arbitrary small datagram. It carries no CRYPTO frame, so a
/// server that did answer would answer with a connection error; the control
/// only cares that NOTHING comes back.
Uint8List quicShapedInitialDatagram([Random? random]) {
  final rng = random ?? Random();
  final bytes = Uint8List(1200);
  bytes[0] = 0xc0; // header form 1, fixed bit 1, Initial (type 0)
  bytes[1] = 0x00;
  bytes[2] = 0x00;
  bytes[3] = 0x00;
  bytes[4] = 0x01; // version 1
  bytes[5] = 8; // destination connection id length
  for (var i = 0; i < 8; i++) {
    bytes[6 + i] = rng.nextInt(256);
  }
  bytes[14] = 8; // source connection id length
  for (var i = 0; i < 8; i++) {
    bytes[15 + i] = rng.nextInt(256);
  }
  // The remaining bytes stay zero: PADDING frames.
  return bytes;
}

/// The `whitelist` map of the job JSON.
///
/// Keys, all optional except `url`:
/// ```
/// url            String   the allowed host's ordinary HTTPS page
/// interval_s     int > 0  seconds between GETs                  (1)
/// blocked_host   String   a host the filter must NOT allow      (192.168.2.9)
/// rst_port       int      the TCP port the RST rule names       (443)
/// quic_port      int      the UDP port the QUIC probe uses      (443)
/// quic_timeout_ms int > 0 how long silence must hold            (3000)
/// relay_only     bool     force the call's ICE to relay/TCP     (false)
/// ```
/// A missing, empty or non-String `url` is rejected loudly with a
/// [FormatException]: without it there is no door to measure, and a run
/// that silently skipped the loop would report an empty `door_samples`
/// and look like a pass.
class WhitelistDoorConfig {
  const WhitelistDoorConfig({
    required this.url,
    this.interval = defaultInterval,
    this.blockedHost = defaultBlockedHost,
    this.rstPort = defaultRstPort,
    this.rstTimeout = defaultRstTimeout,
    this.quicPort = defaultQuicPort,
    this.quicTimeout = defaultQuicTimeout,
    this.relayOnly = false,
  });

  /// Seconds between two GETs of [url].
  static const Duration defaultInterval = Duration(seconds: 1);

  /// Inside the bridge subnet and unrouted, so the only thing that can
  /// answer for it is the filter itself.
  static const String defaultBlockedHost = '192.168.2.9';

  /// The literal port the `block return-rst` rule names. It needs no
  /// listener anywhere: the reset is produced by the filter.
  static const int defaultRstPort = 443;

  /// How long a reset may take before the control is judged a timeout.
  /// Not a job-JSON key: a reset is produced by the first packet's reply,
  /// so this is a ceiling on "fast", not a tunable of the measurement.
  static const Duration defaultRstTimeout = Duration(seconds: 5);

  /// UDP 443 — QUIC. The filter drops it, so nothing may come back.
  static const int defaultQuicPort = 443;

  /// How long silence must hold before the QUIC control passes.
  static const Duration defaultQuicTimeout = Duration(milliseconds: 3000);

  final String url;
  final Duration interval;
  final String blockedHost;
  final int rstPort;
  final Duration rstTimeout;
  final int quicPort;
  final Duration quicTimeout;

  /// True → the call's ICE is forced to relay-only over the TCP TURN URL
  /// for this profile, because every UDP but 53 is dropped.
  final bool relayOnly;

  static WhitelistDoorConfig parse(Map<String, Object?> map) {
    final url = map['url'];
    if (url is! String || url.isEmpty) {
      throw const FormatException(
        'whitelist.url is missing: the door loop has nothing to GET',
      );
    }
    return WhitelistDoorConfig(
      url: url,
      interval: _positiveSeconds(map['interval_s']) ?? defaultInterval,
      blockedHost: _nonEmptyString(map['blocked_host']) ?? defaultBlockedHost,
      rstPort: _port(map['rst_port']) ?? defaultRstPort,
      quicPort: _port(map['quic_port']) ?? defaultQuicPort,
      quicTimeout:
          _positiveMillis(map['quic_timeout_ms']) ?? defaultQuicTimeout,
      relayOnly: map['relay_only'] == true,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'url': url,
    'interval_s': interval.inSeconds,
    'blocked_host': blockedHost,
    'rst_port': rstPort,
    'quic_port': quicPort,
    'quic_timeout_ms': quicTimeout.inMilliseconds,
    'relay_only': relayOnly,
  };

  static String? _nonEmptyString(Object? value) =>
      value is String && value.isNotEmpty ? value : null;

  static int? _port(Object? value) =>
      value is int && value > 0 && value < 65536 ? value : null;

  static Duration? _positiveSeconds(Object? value) =>
      value is int && value > 0 ? Duration(seconds: value) : null;

  static Duration? _positiveMillis(Object? value) =>
      value is int && value > 0 ? Duration(milliseconds: value) : null;
}

/// What one GET answered: the status verbatim and how many body bytes the
/// getter read.
class DoorHttpResponse {
  const DoorHttpResponse({required this.status, required this.bytes});

  final int status;
  final int bytes;

  /// A 2xx is a success. The status is stamped verbatim either way, so a
  /// row can show that the page answered 200 and not a redirect.
  bool get isSuccess => status >= 200 && status < 300;
}

/// One plain HTTPS GET. Throwing is a failed sample, never fatal.
abstract class DoorHttpGetter {
  Future<DoorHttpResponse> get(String url);
}

/// How the reset control's TCP connect ended.
enum TcpProbeOutcome {
  /// The peer (or the filter, on its behalf) sent a reset: the PASS case.
  reset,

  /// The connect completed. The door is open where it must be closed.
  connected,

  /// Nothing came back before the deadline. The packet was dropped, which
  /// is NOT what `block return-rst` does — so this control failed.
  timedOut,

  /// The connector itself failed for a reason that is neither of the above
  /// (name resolution, no route, a platform error).
  error,
}

/// One TCP connect to a host the filter must not allow.
abstract class DoorTcpConnector {
  Future<TcpProbeOutcome> connect({
    required String host,
    required int port,
    required Duration timeout,
  });
}

/// How the QUIC control's datagram ended.
enum UdpProbeOutcome {
  /// Nothing came back within the timeout: the PASS case.
  silent,

  /// Something answered. UDP crossed, which the filter forbids.
  replied,

  /// The prober itself failed (socket could not be opened, no route).
  error,
}

/// One QUIC-shaped UDP datagram, and whether anything answered it.
abstract class DoorUdpProber {
  Future<UdpProbeOutcome> probe({
    required String host,
    required int port,
    required Duration timeout,
  });
}

/// Time, injected: the loop's interval and every measured millisecond come
/// from here, so a test drives the whole unit without waiting.
abstract class DoorClock {
  DateTime nowUtc();
  Future<void> sleep(Duration duration);
}

/// The real clock.
class SystemDoorClock implements DoorClock {
  const SystemDoorClock();

  @override
  DateTime nowUtc() => DateTime.now().toUtc();

  @override
  Future<void> sleep(Duration duration) => Future<void>.delayed(duration);
}

/// The first successful GET: the moment the door was measured open.
class DoorOpen {
  const DoorOpen({
    required this.at,
    required this.tMs,
    required this.status,
    required this.bytes,
  });

  /// UTC wall clock of the answer.
  final DateTime at;

  /// Milliseconds from the loop's start to that answer.
  final int tMs;

  final int status;
  final int bytes;

  Map<String, Object?> toJson() => <String, Object?>{
    'at': at.toIso8601String(),
    't_ms': tMs,
    'status': status,
    'bytes': bytes,
  };
}

/// The reset control's result. [isPass] only for [TcpProbeOutcome.reset].
class ResetProbeResult {
  const ResetProbeResult({required this.outcome, required this.ms});

  final TcpProbeOutcome outcome;

  /// Milliseconds the connect took to reach [outcome].
  final int ms;

  bool get isPass => outcome == TcpProbeOutcome.reset;

  Map<String, Object?> toJson() => <String, Object?>{
    'rst_ms': ms,
    'outcome': outcome.name,
    'pass': isPass,
  };
}

/// The QUIC control's result. [isPass] only for [UdpProbeOutcome.silent].
class QuicProbeResult {
  const QuicProbeResult({required this.outcome, required this.ms});

  final UdpProbeOutcome outcome;

  /// Milliseconds of silence (or until the reply / error).
  final int ms;

  bool get isPass => outcome == UdpProbeOutcome.silent;

  Map<String, Object?> toJson() => <String, Object?>{
    'timeout_ms': ms,
    'outcome': outcome.name,
    'pass': isPass,
  };
}

/// The ordinary-traffic loop and the two negative controls.
///
/// [run] loops until [stop]; it never throws — a getter that throws is a
/// failed sample and the loop continues, because the evidence channel must
/// not be able to end the call that runs beside it.
class WhitelistDoor {
  WhitelistDoor({
    required this.config,
    required this.http,
    required this.tcp,
    required this.udp,
    required this.clock,
    this.onOpen,
    this.log,
  });

  final WhitelistDoorConfig config;
  final DoorHttpGetter http;
  final DoorTcpConnector tcp;
  final DoorUdpProber udp;
  final DoorClock clock;

  /// Called exactly once, with the first successful sample.
  final void Function(DoorOpen open)? onOpen;

  final void Function(String line)? log;

  DateTime? _startedAt;
  DoorOpen? _firstOpen;
  int _ok = 0;
  int _fail = 0;
  bool _running = false;
  ResetProbeResult? _reset;
  QuicProbeResult? _quic;

  /// Successful samples so far.
  int get ok => _ok;

  /// Failed samples so far (a non-2xx status, or a getter that threw).
  int get fail => _fail;

  /// The first successful sample, or null while the door has never opened.
  DoorOpen? get firstOpen => _firstOpen;

  bool get isRunning => _running;

  /// The cached reset control, once [probeResetElsewhere] has run.
  ResetProbeResult? get resetResult => _reset;

  /// The cached QUIC control, once [probeQuicDead] has run.
  QuicProbeResult? get quicResult => _quic;

  /// `door_samples` for the `ended` report.
  Map<String, Object?> samplesJson() => <String, Object?>{
    'ok': _ok,
    'fail': _fail,
  };

  /// Loops one GET per [WhitelistDoorConfig.interval] until [stop].
  /// Calling it while already running is a no-op.
  Future<void> run() async {
    if (_running) return;
    _running = true;
    _startedAt = clock.nowUtc();
    while (_running) {
      await _sample();
      if (!_running) break;
      await clock.sleep(config.interval);
    }
  }

  /// Ends the loop after the sample in flight.
  void stop() => _running = false;

  Future<void> _sample() async {
    DoorHttpResponse? response;
    try {
      response = await http.get(config.url);
    } on Object catch (error) {
      _fail++;
      log?.call('door GET ${config.url} failed: $error');
      return;
    }
    if (!response.isSuccess) {
      _fail++;
      log?.call('door GET ${config.url} status=${response.status}');
      return;
    }
    _ok++;
    if (_firstOpen != null) return;
    final at = clock.nowUtc();
    final open = _firstOpen = DoorOpen(
      at: at,
      tMs: at.difference(_startedAt ?? at).inMilliseconds,
      status: response.status,
      bytes: response.bytes,
    );
    log?.call(
      'door open t_ms=${open.tMs} status=${open.status} bytes=${open.bytes}',
    );
    onOpen?.call(open);
  }

  /// The reset control, run at most once; later calls return the same
  /// result so the peer reports it exactly once.
  Future<ResetProbeResult> probeResetElsewhere() async {
    final cached = _reset;
    if (cached != null) return cached;
    final startedAt = clock.nowUtc();
    TcpProbeOutcome outcome;
    try {
      outcome = await tcp.connect(
        host: config.blockedHost,
        port: config.rstPort,
        timeout: config.rstTimeout,
      );
    } on Object catch (error) {
      log?.call('door reset probe failed: $error');
      outcome = TcpProbeOutcome.error;
    }
    final result = _reset = ResetProbeResult(
      outcome: outcome,
      ms: clock.nowUtc().difference(startedAt).inMilliseconds,
    );
    log?.call(
      'door closed elsewhere outcome=${result.outcome.name} '
      'ms=${result.ms} pass=${result.isPass}',
    );
    return result;
  }

  /// The QUIC control, run at most once; later calls return the same result.
  Future<QuicProbeResult> probeQuicDead() async {
    final cached = _quic;
    if (cached != null) return cached;
    final startedAt = clock.nowUtc();
    UdpProbeOutcome outcome;
    try {
      outcome = await udp.probe(
        host: config.blockedHost,
        port: config.quicPort,
        timeout: config.quicTimeout,
      );
    } on Object catch (error) {
      log?.call('door quic probe failed: $error');
      outcome = UdpProbeOutcome.error;
    }
    final result = _quic = QuicProbeResult(
      outcome: outcome,
      ms: clock.nowUtc().difference(startedAt).inMilliseconds,
    );
    log?.call(
      'quic dead outcome=${result.outcome.name} '
      'ms=${result.ms} pass=${result.isPass}',
    );
    return result;
  }
}
