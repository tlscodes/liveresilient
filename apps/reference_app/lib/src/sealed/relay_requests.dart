// What this install costs the relay: counted, capped, and never held open.
//
// The border relay is shared by every install and is paid for by the request.
// So every request the sealed-letter service sends goes through
// [MeteredRelayTransport], which
//
//   * takes it from the day's allowance BEFORE it leaves, and refuses it when
//     the allowance is used up — looking stops first, so the last share of a
//     day is kept for writing;
//   * cuts it off at a hard limit: a look, a pointer, a receipt or a text is
//     never open longer than [MeteredRelayTransport.probeLimit]. Only a
//     request that carries a piece of a photo, a voice note or a video may
//     stay open longer, in proportion to its size;
//   * times it, so "how long was the longest request open" is a number the
//     diagnostics screen and the journal can show.
//
// Nothing here waits on the relay to say something: there is no long-poll.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:broadcast/broadcast.dart'
    show BroadcastHttpResponse, BroadcastHttpTransport;
import 'package:flutter/foundation.dart';

/// The request counter as a screen can show it.
@immutable
class RequestCount {
  const RequestCount({
    required this.day,
    required this.usedToday,
    required this.dailyCap,
    required this.lookCap,
    required this.sinceStart,
    required this.refusedToday,
    required this.longestOpen,
    required this.openNow,
  });

  /// Days since the epoch, UTC: the day [usedToday] belongs to.
  final int day;
  final int usedToday;
  final int dailyCap;

  /// Looking stops here; what is left of [dailyCap] is for writing.
  final int lookCap;

  /// Requests since this process started, across midnights.
  final int sinceStart;

  /// Requests that were not sent today because the allowance was used up.
  final int refusedToday;

  /// The longest any request has been open since this process started.
  final Duration longestOpen;
  final int openNow;

  bool get looksSpent => usedToday >= lookCap;
  bool get spent => usedToday >= dailyCap;
}

/// Where the day's count is kept between launches, so that closing and
/// opening the app does not hand out a fresh allowance.
abstract class RequestLedger {
  /// The day and count last written; null when there is none.
  ({int day, int used})? read();
  void write(int day, int used);
}

class MemoryRequestLedger implements RequestLedger {
  ({int day, int used})? _held;

  @override
  ({int day, int used})? read() => _held;

  @override
  void write(int day, int used) => _held = (day: day, used: used);
}

/// One small file, replaced whole: a count is never half written.
class FileRequestLedger implements RequestLedger {
  FileRequestLedger(this.directory);

  final Directory Function() directory;
  static const String fileName = 'sealed_requests.json';

  File get _file => File('${directory().path}/$fileName');

  @override
  ({int day, int used})? read() {
    try {
      final map = jsonDecode(_file.readAsStringSync()) as Map;
      return (
        day: (map['day'] as num).toInt(),
        used: (map['used'] as num).toInt(),
      );
    } catch (_) {
      return null;
    }
  }

  @override
  void write(int day, int used) {
    try {
      final file = _file;
      file.parent.createSync(recursive: true);
      final next = File('${file.path}.next')
        ..writeAsStringSync(jsonEncode({'day': day, 'used': used}));
      next.renameSync(file.path);
    } catch (_) {
      // The count in memory still holds for the life of this process.
    }
  }
}

/// This install's daily allowance of relay requests.
class RequestBudget {
  RequestBudget({
    this.dailyCap = 3000,
    this.lookShare = 0.8,
    DateTime Function()? clock,
    RequestLedger? ledger,
  }) : assert(dailyCap > 0),
       assert(lookShare > 0 && lookShare <= 1),
       _clock = clock ?? DateTime.now,
       _ledger = ledger ?? MemoryRequestLedger() {
    _day = _today();
    final kept = _ledger.read();
    if (kept != null && kept.day == _day) _used = kept.used;
    count = ValueNotifier<RequestCount>(_snapshot());
  }

  /// The most requests this install sends the relay in one UTC day.
  final int dailyCap;

  /// The part of [dailyCap] that looking may use.
  final double lookShare;
  final DateTime Function() _clock;
  final RequestLedger _ledger;

  late final ValueNotifier<RequestCount> count;

  late int _day;
  int _used = 0;
  int _refused = 0;
  int _sinceStart = 0;
  int _openNow = 0;
  Duration _longest = Duration.zero;

  int get lookCap => (dailyCap * lookShare).floor();

  int _today() =>
      _clock().toUtc().millisecondsSinceEpoch ~/ Duration.millisecondsPerDay;

  void _roll() {
    final today = _today();
    if (today == _day) return;
    _day = today;
    _used = 0;
    _refused = 0;
  }

  RequestCount _snapshot() => RequestCount(
    day: _day,
    usedToday: _used,
    dailyCap: dailyCap,
    lookCap: lookCap,
    sinceStart: _sinceStart,
    refusedToday: _refused,
    longestOpen: _longest,
    openNow: _openNow,
  );

  /// The counter as it is now (the day rolled over if it has).
  RequestCount get now {
    _roll();
    return count.value = _snapshot();
  }

  /// When the allowance is whole again: the next UTC midnight.
  DateTime get nextDay => DateTime.fromMillisecondsSinceEpoch(
    (_today() + 1) * Duration.millisecondsPerDay,
    isUtc: true,
  );

  /// Takes one request from today's allowance. False when there is none
  /// left for it: a look past [lookCap], anything past [dailyCap].
  bool take({required bool write}) {
    _roll();
    if (_used >= (write ? dailyCap : lookCap)) {
      _refused++;
      count.value = _snapshot();
      return false;
    }
    _used++;
    _sinceStart++;
    _openNow++;
    _ledger.write(_day, _used);
    count.value = _snapshot();
    return true;
  }

  /// A request taken with [take] is over, having been open for [open].
  void done(Duration open) {
    if (_openNow > 0) _openNow--;
    if (open > _longest) _longest = open;
    count.value = _snapshot();
  }
}

/// Thrown instead of sending when the day's allowance is used up.
class RequestBudgetSpent implements Exception {
  const RequestBudgetSpent();

  @override
  String toString() => "today's relay request allowance is used up";
}

/// The relay's HTTP surface for sealed letters: counted against a
/// [RequestBudget], timed, and cut off at a hard limit.
class MeteredRelayTransport implements BroadcastHttpTransport {
  MeteredRelayTransport({
    required this.budget,
    HttpClient? client,
    this.probeLimit = const Duration(milliseconds: 1800),
    this.smallBody = 4096,
    this.slowestBytesPerSecond = 2000,
    this.maxResponseBytes = 256 * 1024,
    this.onRequest,
  }) : _client = client ?? HttpClient() {
    // Reaching the relay is part of the request: it gets no time of its own.
    _client.connectionTimeout = probeLimit;
  }

  final RequestBudget budget;
  final HttpClient _client;

  /// The longest a request that carries no more than [smallBody] bytes
  /// either way may be open, from before the connection to the last byte.
  /// Kept under two seconds with room for the clock that enforces it.
  final Duration probeLimit;
  final int smallBody;

  /// A larger body buys time at this rate: the slowest link a piece of
  /// media is still worth waiting for.
  final int slowestBytesPerSecond;
  final int maxResponseBytes;

  /// Every request as it ends: how long it was open and whether it was cut.
  final void Function(Duration open, {required bool write, required bool cut})?
  onRequest;

  Duration _limitFor(int bytes) => bytes <= smallBody
      ? probeLimit
      : probeLimit +
            Duration(
              milliseconds: (bytes - smallBody) * 1000 ~/ slowestBytesPerSecond,
            );

  @override
  Future<BroadcastHttpResponse> get(Uri url) => _send('GET', url, null);

  @override
  Future<BroadcastHttpResponse> put(
    Uri url,
    Uint8List body, {
    Map<String, String> headers = const {},
  }) => _send('PUT', url, body, headers);

  Future<BroadcastHttpResponse> _send(
    String method,
    Uri url,
    Uint8List? body, [
    Map<String, String> headers = const {},
  ]) async {
    final write = body != null;
    if (!budget.take(write: write)) throw const RequestBudgetSpent();
    final open = Stopwatch()..start();
    final result = Completer<BroadcastHttpResponse>();
    HttpClientRequest? request;
    StreamSubscription<List<int>>? reading;
    Completer<Uint8List?>? bodyRead;
    Timer? timer;
    var cut = false;

    void cutNow() {
      if (result.isCompleted) return;
      cut = true;
      // Before the response has started this closes the connection; once
      // it has, cancelling the read does.
      request?.abort();
      unawaited(reading?.cancel());
      final pending = bodyRead;
      if (pending != null && !pending.isCompleted) pending.complete(null);
      result.completeError(
        TimeoutException('relay request cut off', open.elapsed),
      );
    }

    void arm(Duration limit) {
      timer?.cancel();
      final left = limit - open.elapsed;
      timer = Timer(left.isNegative ? Duration.zero : left, cutNow);
    }

    arm(_limitFor(body?.length ?? 0));
    unawaited(() async {
      try {
        final sent = request = await _client.openUrl(method, url);
        if (result.isCompleted) {
          sent.abort();
          return;
        }
        for (final entry in headers.entries) {
          sent.headers.set(entry.key, entry.value);
        }
        // Every address here is immutable and content addressed: a
        // redirect can only lead somewhere that was not named.
        sent.followRedirects = false;
        if (body != null) {
          sent.headers.contentType = ContentType.binary;
          sent.contentLength = body.length;
          sent.add(body);
        }
        final response = await sent.close();
        if (result.isCompleted) {
          unawaited(response.listen((_) {}).cancel());
          return;
        }
        if (response.statusCode != HttpStatus.ok) {
          await response.drain<void>();
          if (!result.isCompleted) {
            result.complete(
              BroadcastHttpResponse(statusCode: response.statusCode),
            );
          }
          return;
        }
        // A body is coming: it may take the time its size is worth.
        final declared = response.contentLength;
        arm(_limitFor(declared >= 0 ? declared : maxResponseBytes));
        final read = bodyRead = Completer<Uint8List?>();
        final bytes = BytesBuilder(copy: false);
        reading = response.listen(
          (chunk) {
            bytes.add(chunk);
            if (bytes.length > maxResponseBytes && !read.isCompleted) {
              unawaited(reading?.cancel());
              read.complete(null);
            }
          },
          onError: (Object error, StackTrace stack) {
            if (!read.isCompleted) read.completeError(error, stack);
          },
          onDone: () {
            if (!read.isCompleted) read.complete(bytes.takeBytes());
          },
          cancelOnError: true,
        );
        final whole = await read.future;
        if (result.isCompleted) return;
        result.complete(
          whole == null
              // Over the ceiling: to the caller this relay has nothing
              // usable, which is what a refusal says.
              ? const BroadcastHttpResponse(
                  statusCode: HttpStatus.requestEntityTooLarge,
                )
              : BroadcastHttpResponse(statusCode: HttpStatus.ok, body: whole),
        );
      } catch (error, stack) {
        if (!result.isCompleted) result.completeError(error, stack);
      }
    }());

    try {
      return await result.future;
    } finally {
      timer?.cancel();
      open.stop();
      budget.done(open.elapsed);
      onRequest?.call(open.elapsed, write: write, cut: cut);
    }
  }

  void close() => _client.close(force: true);
}
