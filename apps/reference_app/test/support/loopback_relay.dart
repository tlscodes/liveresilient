// What the sealed-letter tests stand on, without a device: a relay on
// loopback that keeps the border relay's archive contract, and an install
// with its own keystore, pins, letter file, clock and request allowance.
//
// The relay: `/o/<hash>` must hash to its name, `/a/<author>/<seq>` must
// prove its author with the same three-link check the worker runs, and both
// are write-once. Every request is written down as it arrives, so a test
// can say what an install cost. Lab only: nothing here is a device result.
//
// For plain `test`, never `testWidgets`: the widget binding replaces
// HttpClient.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:reference_app/src/intelligence/disk_json_storage.dart';
import 'package:reference_app/src/peer_identity.dart';
import 'package:reference_app/src/sealed/pair_shelf.dart';
import 'package:reference_app/src/sealed/relay_requests.dart';
import 'package:reference_app/src/sealed/sealed_blob_store.dart';
import 'package:reference_app/src/sealed/sealed_letter_service.dart';
import 'package:security/security.dart';

class MemoryStorage implements PersistentStorage {
  Map<String, Object?> data = {};

  @override
  Future<Map<String, Object?>> load() async =>
      jsonDecode(jsonEncode(data)) as Map<String, Object?>;

  @override
  Future<void> save(Map<String, Object?> data) async {
    this.data = jsonDecode(jsonEncode(data)) as Map<String, Object?>;
  }
}

String hexOf(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

Uint8List utf8Of(String text) => Uint8List.fromList(utf8.encode(text));

bool containsBytes(List<int> haystack, List<int> needle) {
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    var hit = true;
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) {
        hit = false;
        break;
      }
    }
    if (hit) return true;
  }
  return false;
}

/// The border relay's archive on loopback.
class LoopbackRelay {
  LoopbackRelay._(this._server);

  static Future<LoopbackRelay> start() async {
    final relay = LoopbackRelay._(await HttpServer.bind('127.0.0.1', 0));
    relay._server.listen(relay._serve);
    return relay;
  }

  final HttpServer _server;

  /// What is on the relay, in the order it was put there.
  final Map<String, Uint8List> objects = {};
  final Map<String, Uint8List> pointers = {};

  /// Every request as it arrived: `GET /a/<author>/<seq>`, `PUT /o/<hash>`.
  final List<String> requests = [];

  /// Answer 503 to everything.
  bool down = false;

  /// Reads work, writes are refused: the relay is reachable but full.
  bool refuseWrites = false;
  int refusedPointerWrites = 0;

  Uri get origin => Uri.parse('http://127.0.0.1:${_server.port}');

  int get gets => requests.where((r) => r.startsWith('GET ')).length;
  int get puts => requests.where((r) => r.startsWith('PUT ')).length;

  /// The relay's two days are up.
  void expireEverything() {
    objects.clear();
    pointers.clear();
  }

  Future<Uint8List> _body(HttpRequest request) async {
    final body = BytesBuilder();
    await for (final chunk in request) {
      body.add(chunk);
    }
    return body.takeBytes();
  }

  Future<String> _sha(List<int> bytes) async =>
      hexOf((await Sha256().hash(bytes)).bytes);

  Future<bool> _signed(List<int> key, List<int> message, List<int> sig) =>
      Ed25519().verify(
        message,
        signature: Signature(
          sig,
          publicKey: SimplePublicKey(key, type: KeyPairType.ed25519),
        ),
      );

  /// The worker's `authorizeDescriptorWrite`, link for link.
  Future<bool> _authorised(
    String author,
    Uint8List pointer,
    String? header,
  ) async {
    if (header == null) return false;
    final Uint8List credentials;
    try {
      credentials = base64Url.decode(base64Url.normalize(header));
    } on FormatException {
      return false;
    }
    if (credentials.length != 32 + 125) return false;
    final root = credentials.sublist(0, 32);
    final certificate = credentials.sublist(32);
    if ((await _sha(root)).substring(0, 32) != author) return false;
    if (hexOf(certificate.sublist(1, 17)) != author) return false;
    if (!await _signed(root, [
      ...utf8.encode('vck/broadcast/publishing-key/v1\n'),
      ...certificate.sublist(0, 125 - 64),
    ], certificate.sublist(125 - 64))) {
      return false;
    }
    if (pointer.length < 2 + 16 + 64) return false;
    if (hexOf(pointer.sublist(2, 18)) != author) return false;
    return _signed(certificate.sublist(17, 49), [
      ...utf8.encode('vck/broadcast/descriptor/v1\n'),
      ...pointer.sublist(0, pointer.length - 64),
    ], pointer.sublist(pointer.length - 64));
  }

  Future<void> _serve(HttpRequest request) async {
    final response = request.response;
    final path = request.uri.path;
    final write = request.method == 'PUT' || request.method == 'POST';
    requests.add('${request.method} $path');
    final body = write ? await _body(request) : Uint8List(0);
    if (!write) await request.drain<void>();
    if (down || (write && refuseWrites)) {
      response.statusCode = 503;
    } else if (path.startsWith('/o/')) {
      final hash = path.substring(3);
      if (!write) {
        final held = objects[hash];
        response.statusCode = held == null ? 404 : 200;
        if (held != null) response.add(held);
      } else if (body.isEmpty) {
        response.statusCode = 400;
      } else if (body.length > 100000) {
        response.statusCode = 413;
      } else if (await _sha(body) != hash) {
        response.statusCode = 400;
      } else {
        response.statusCode = objects.containsKey(hash) ? 204 : 201;
        objects[hash] = body;
      }
    } else if (path.startsWith('/a/')) {
      final key = path.substring(3);
      final author = key.split('/').first;
      if (!write) {
        final held = pointers[key];
        response.statusCode = held == null ? 404 : 200;
        if (held != null) response.add(held);
      } else if (body.isEmpty || body.length > 512) {
        response.statusCode = body.isEmpty ? 400 : 413;
      } else if (!await _authorised(
        author,
        body,
        request.headers.value('x-broadcast-auth'),
      )) {
        refusedPointerWrites++;
        response.statusCode = 403;
      } else {
        final held = pointers[key];
        if (held == null) {
          pointers[key] = body;
          response.statusCode = 201;
        } else {
          response.statusCode = hexOf(held) == hexOf(body) ? 204 : 409;
        }
      }
    } else {
      // No long-poll route, no mailbox: nothing else exists here.
      response.statusCode = 404;
    }
    await response.close();
  }

  Future<void> stop() => _server.close(force: true);
}

/// One install: its own keystore, pins, letter file, pieces, clock and
/// request allowance.
class TestInstall {
  TestInstall({MemoryStorage? pins})
    : identity = AppIdentity(
        engine: CryptographyIdentityKeyEngine(keyStore: InMemoryKeyStore()),
        pins: PinnedPeerStore(pins ?? MemoryStorage()),
      );

  final AppIdentity identity;
  final MemoryStorage letters = MemoryStorage();
  final MemorySealedBlobStore blobs = MemorySealedBlobStore();
  final MemoryRequestLedger ledger = MemoryRequestLedger();
  final List<(String, Map<String, Object?>)> events = [];
  DateTime now = DateTime.utc(2026, 10, 5, 12);
  late final Uint8List idBytes;
  late final String id;
  late final Uint8List key;

  Future<void> ready() async {
    idBytes = await identity.installId();
    id = hexOf(idBytes);
    key = (await identity.store.localIdentity()).publicKey;
  }

  /// What a call's identity exchange leaves behind: [other]'s key pinned.
  Future<void> pin(TestInstall other) => identity.store.checkRemoteIdentity(
    peerId: other.id,
    presentedPublicKey: other.key,
  );

  /// Today's allowance as a launch finds it: the count is in the ledger.
  RequestBudget budget({int dailyCap = 3000, double lookShare = 0.8}) =>
      RequestBudget(
        dailyCap: dailyCap,
        lookShare: lookShare,
        clock: () => now,
        ledger: ledger,
      );

  PairShelf shelf(LoopbackRelay relay, {RequestBudget? budget}) => PairShelf(
    identity: identity,
    origin: relay.origin,
    transport: MeteredRelayTransport(budget: budget ?? this.budget()),
    clock: () => now,
  );

  /// A fresh service over the same files — what switching the app on is.
  SealedLetterService service(
    LoopbackRelay relay, {
    RequestBudget? budget,
    Future<void> Function(Duration wait)? sleep,
    Duration aliveEvery = const Duration(seconds: 30),
  }) {
    final allowance = budget ?? this.budget();
    return SealedLetterService(
      identity: identity,
      shelf: shelf(relay, budget: allowance),
      storage: letters,
      blobs: blobs,
      budget: allowance,
      clock: () => now,
      sleep: sleep,
      aliveEvery: aliveEvery,
      onEvent: (event, fields) => events.add((event, fields)),
    );
  }

  Iterable<Map<String, Object?>> of(String event) =>
      events.where((e) => e.$1 == event).map((e) => e.$2);
}

/// A clock the schedule runs on in an instant: the service's own `sleep`
/// moves it forward, so hours of looks happen as fast as they can be asked.
class SimClock {
  SimClock(this.start) : now = start;

  final DateTime start;
  DateTime now;

  /// The run parks here: [reached] completes and the loop sleeps for good.
  /// Setting it again lets a later run go on from where this one parked.
  DateTime? get until => _until;
  set until(DateTime? value) {
    _until = value;
    _reached = false;
    _onReached = null;
  }

  DateTime? _until;
  final List<({Duration at, Future<void> Function() run})> _planned = [];
  bool _reached = false;
  void Function()? _onReached;

  /// Something that happens [at] this long after the start.
  void plan(Duration at, Future<void> Function() run) {
    _planned
      ..add((at: at, run: run))
      ..sort((a, b) => a.at.compareTo(b.at));
  }

  /// Completes when the clock has reached [until].
  Future<void> get reached {
    if (_reached) return Future<void>.value();
    final done = Completer<void>();
    _onReached = done.complete;
    return done.future;
  }

  Future<void> sleep(Duration wait) async {
    final target = now.add(wait);
    final end = until;
    final plannedAt = _planned.isEmpty ? null : start.add(_planned.first.at);
    // What is planned for after the run's end stays planned for a later run.
    if (plannedAt != null &&
        !plannedAt.isAfter(target) &&
        (end == null || !plannedAt.isAfter(end))) {
      final next = _planned.removeAt(0);
      if (plannedAt.isAfter(now)) now = plannedAt;
      await next.run();
      return;
    }
    if (end != null && target.isAfter(end)) {
      if (end.isAfter(now)) now = end;
      _reached = true;
      _onReached?.call();
      // Parked: only stop() ends this wait.
      return Completer<void>().future;
    }
    now = target;
  }
}
