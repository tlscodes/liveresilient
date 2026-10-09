// SECTION ب, Dart proof: the give gateway carried over the real TXT lane.
//
// A fake [TxtQueryTransport] stands in for the give gateway + our own relay: it
// speaks the REAL wire (TxtQueryWire parses the DNS query, reassembles the give
// request by seq, replays it against an in-memory relay map, and queues the give
// response back down the lane in budget-sized frames). So what is exercised here
// is the real uplink/poll/drain logic of [TxtLaneBroadcastTransport], not a mock
// of it. The box per kind is opaque bytes — give holds no key and never decodes
// it — so byte-for-byte equality across the lane is the property proven.

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:adaptive_transport/adaptive_transport.dart'
    show TxtQueryTransport, TxtQueryWire;
import 'package:broadcast/broadcast.dart'
    show BroadcastHttpResponse, BroadcastHttpTransport;
import 'package:flutter_test/flutter_test.dart';
import 'package:reference_app/src/sealed/txt_lane_transport.dart';

const String _domain = 'valve.test';

// Representative opaque sealed-box sizes, one per kind. Seeded so the bytes are
// stable run to run; their content is irrelevant to give.
const Map<String, int> _kinds = <String, int>{
  'text': 313,
  'photo': 5000,
  'voice30': 3007,
  'video': 12000,
};

Uint8List _box(int seed, int n) {
  final r = Random(seed);
  final b = Uint8List(n);
  for (var i = 0; i < n; i++) {
    b[i] = r.nextInt(256);
  }
  return b;
}

void main() {
  group('give over the TXT lane', () {
    test('four kinds: written and opened, SHA equal, via=txt', () async {
      final relay = <String, Uint8List>{};
      final give = _FakeGiveTransport(_domain, relay);
      final txt = TxtLaneBroadcastTransport(
        transport: give,
        domain: _domain,
        drainTimeout: const Duration(seconds: 10),
      );
      // The direct path is cut: HTTPS throws, so every request must ride the lane.
      final https = _FakeHttpsTransport(throwing: true);
      final fallback = FallbackBroadcastTransport(
        https: https,
        txt: txt,
        networkId: () => 'cut-net',
      );

      final rows = <String>['kind\tdir\tvia\tbytes\tok'];
      var seed = 1;
      for (final entry in _kinds.entries) {
        final box = _box(seed++, entry.value);
        final url = Uri(path: '/box/${entry.key}');

        final put = await fallback.put(url, box);
        expect(put.statusCode, 200, reason: '${entry.key} PUT');
        rows.add('${entry.key}\tput\ttxt\t${box.length}\tPASS');

        final got = await fallback.get(url);
        expect(got.statusCode, 200, reason: '${entry.key} GET');
        expect(got.body, isNotNull, reason: '${entry.key} body');
        // Byte-for-byte equality is strictly stronger than SHA equality.
        expect(got.body, orderedEquals(box), reason: '${entry.key} bytes');
        rows.add('${entry.key}\tget\ttxt\t${got.body!.length}\tPASS');
      }

      // A miss is a clean 404 carried through the lane, not a hang.
      final miss = await fallback.get(Uri(path: '/box/absent'));
      expect(miss.statusCode, 404, reason: 'absent box');
      rows.add('absent\tget\ttxt\t0\tPASS');

      // via=txt: HTTPS threw, the lane carried every request, and the network is
      // remembered so the next request skips the HTTPS timeout.
      expect(fallback.prefersTxt('cut-net'), isTrue);
      expect(give.exchanges, greaterThan(0));
      // ignore: avoid_print
      print(rows.join('\n'));
      await txt.dispose();
    });

    test('HTTPS first when it answers: the lane is never touched', () async {
      final give = _FakeGiveTransport(_domain, <String, Uint8List>{});
      final txt = TxtLaneBroadcastTransport(transport: give, domain: _domain);
      final https = _FakeHttpsTransport(throwing: false);
      final fallback = FallbackBroadcastTransport(
        https: https,
        txt: txt,
        networkId: () => 'good-net',
      );

      final box = _box(9, 64);
      final url = Uri(path: '/box/https-first');
      expect((await fallback.put(url, box)).statusCode, 200);
      final got = await fallback.get(url);
      expect(got.statusCode, 200);
      expect(got.body, orderedEquals(box));

      expect(
        give.exchanges,
        0,
        reason: 'lane must stay untouched when HTTPS works',
      );
      expect(fallback.prefersTxt('good-net'), isFalse);
      await txt.dispose();
    });

    test(
      'TXT on throw, then HTTPS is skipped on that network next time',
      () async {
        final give = _FakeGiveTransport(_domain, <String, Uint8List>{});
        final txt = TxtLaneBroadcastTransport(transport: give, domain: _domain);
        final https = _FakeHttpsTransport(throwing: true);
        final fallback = FallbackBroadcastTransport(
          https: https,
          txt: txt,
          networkId: () => 'A',
        );

        final box = _box(3, 200);
        final url = Uri(path: '/box/mem');
        await fallback.put(url, box); // HTTPS throws -> TXT carries it
        final callsAfterFirst = https.calls;
        expect(callsAfterFirst, greaterThan(0));
        expect(fallback.prefersTxt('A'), isTrue);

        // A known-TXT network must not pay the HTTPS timeout again.
        final got = await fallback.get(url);
        expect(got.statusCode, 200);
        expect(got.body, orderedEquals(box));
        expect(
          https.calls,
          callsAfterFirst,
          reason: 'HTTPS not retried on a known-TXT network',
        );
        await txt.dispose();
      },
    );

    test(
      'per-network memory: a different network still tries HTTPS first',
      () async {
        var network = 'A';
        final give = _FakeGiveTransport(_domain, <String, Uint8List>{});
        final txt = TxtLaneBroadcastTransport(transport: give, domain: _domain);
        final https = _FakeHttpsTransport(throwing: true);
        final fallback = FallbackBroadcastTransport(
          https: https,
          txt: txt,
          networkId: () => network,
        );

        // Network A: HTTPS down -> lane, A remembered.
        await fallback.put(Uri(path: '/box/a'), _box(1, 100));
        expect(fallback.prefersTxt('A'), isTrue);

        // Network B: HTTPS recovers; B must try HTTPS first (not inherit A's memory).
        network = 'B';
        https.throwing = false;
        final callsBefore = https.calls;
        final got = await fallback.get(Uri(path: '/box/a'));
        // B's HTTPS was asked (calls grew) and B is not a TXT network.
        expect(https.calls, greaterThan(callsBefore));
        expect(fallback.prefersTxt('B'), isFalse);
        // The relay was empty for '/box/a' over HTTPS, so B sees a clean 404.
        expect(got.statusCode, 404);
        await txt.dispose();
      },
    );

    test(
      'numbered chunks reassemble out of order; a re-sent chunk is harmless',
      () async {
        final relay = <String, Uint8List>{};
        final give = _FakeGiveTransport(_domain, relay);
        final body = _box(7, 500);
        final request = encodeGiveRequest(
          2 /* PUT */,
          '/box/reorder',
          const {},
          body,
        );
        final encoded = TxtQueryWire.encodeQueries(request, _domain);
        final names = encoded.names;
        expect(
          names.length,
          greaterThan(2),
          reason: 'need several chunks to reorder meaningfully',
        );

        // Send a duplicate of a middle seq first, then every seq in reverse order.
        final order = <int>[
          names.length ~/ 2,
          for (var i = names.length - 1; i >= 0; i--) i,
        ];
        final carried = <int>[];
        var txid = 0x2000;
        for (final seq in order) {
          final packet = TxtQueryWire.buildDnsQueryPacket(txid, names[seq]);
          final answer = TxtQueryWire.parseDnsAnswerPacket(
            await give.exchange(packet, txid++, const Duration(seconds: 1)),
          );
          // The exchange that completes the request already carries the first
          // downlink bytes; keep them so the response is not lost.
          if (answer.payload != null) {
            carried.addAll(TxtQueryWire.unframeDown(answer.payload!));
          }
        }

        // Despite the order and the duplicate, the PUT reassembled correctly.
        expect(relay['/box/reorder'], orderedEquals(body));
        // And the queued 200 drains cleanly (seeded with what the uplink carried).
        final drained = await _drain(give, encoded.sessionId, carried);
        expect(drained.statusCode, 200);
      },
    );
  });
}

// Polls the fake directly (seq == seqMax) and decodes the give response, so the
// reassembly test can confirm the response drains after an out-of-order upload.
Future<BroadcastHttpResponse> _drain(
  TxtQueryTransport t,
  String session, [
  List<int>? seed,
]) async {
  final buf = seed ?? <int>[];
  int? total;
  for (var i = 0; i < 100000; i++) {
    if (total == null && buf.length >= 8) {
      total = 8 + ((buf[4] << 24) | (buf[5] << 16) | (buf[6] << 8) | buf[7]);
    }
    if (total != null && buf.length >= total) break;
    final name = TxtQueryWire.buildQueryName(
      const <int>[],
      TxtQueryWire.seqMax,
      session,
      TxtQueryWire.newNonce(),
      _domain,
    );
    final txid = 0x3000 + (i & 0xFFF);
    final packet = TxtQueryWire.buildDnsQueryPacket(txid, name);
    final answer = TxtQueryWire.parseDnsAnswerPacket(
      await t.exchange(packet, txid, const Duration(seconds: 1)),
    );
    final carried = answer.payload;
    if (carried != null) buf.addAll(TxtQueryWire.unframeDown(carried));
  }
  final status = (buf[2] << 8) | buf[3];
  final n = (buf[4] << 24) | (buf[5] << 16) | (buf[6] << 8) | buf[7];
  return BroadcastHttpResponse(
    statusCode: status,
    body: Uint8List.fromList(buf.sublist(8, 8 + n)),
  );
}

/// A fake HTTPS transport: throws (relay unreachable) or acts as a tiny relay.
class _FakeHttpsTransport implements BroadcastHttpTransport {
  _FakeHttpsTransport({required this.throwing});
  bool throwing;
  int calls = 0;
  final Map<String, Uint8List> store = <String, Uint8List>{};

  @override
  Future<BroadcastHttpResponse> get(Uri url) async {
    calls++;
    if (throwing) throw Exception('relay unreachable');
    final hit = store[url.path];
    if (hit == null) return const BroadcastHttpResponse(statusCode: 404);
    return BroadcastHttpResponse(statusCode: 200, body: hit);
  }

  @override
  Future<BroadcastHttpResponse> put(
    Uri url,
    Uint8List body, {
    Map<String, String> headers = const {},
  }) async {
    calls++;
    if (throwing) throw Exception('relay unreachable');
    store[url.path] = body;
    return const BroadcastHttpResponse(statusCode: 200);
  }
}

/// The give gateway + our own relay, behind one [TxtQueryTransport], speaking the
/// real wire. It reassembles the give request by seq (order-independent and
/// duplicate-safe), replays it against [relay], and queues the give response down
/// the lane in budget-sized frames.
class _FakeGiveTransport implements TxtQueryTransport {
  _FakeGiveTransport(this.domain, this.relay);
  final String domain;
  final Map<String, Uint8List> relay;
  int exchanges = 0;

  final Map<String, Map<int, Uint8List>> _up = <String, Map<int, Uint8List>>{};
  final Map<String, List<int>> _down = <String, List<int>>{};

  @override
  String get label => 'fake-give:$domain';

  @override
  Future<void> dispose() async {}

  @override
  Future<Uint8List> exchange(
    Uint8List query,
    int txid,
    Duration timeout,
  ) async {
    exchanges++;
    final q = TxtQueryWire.parseDnsQueryPacket(query);
    final pq = TxtQueryWire.parseQueryName(q.name, domain);
    final session = pq.sessionId;
    if (pq.seq != TxtQueryWire.seqMax) {
      (_up[session] ??= <int, Uint8List>{})[pq.seq] = pq.chunk;
      final payload = _complete(session);
      if (payload != null) _handle(session, payload);
    }
    return TxtQueryWire.buildDnsAnswerPacket(txid, q.name, _nextDown(session));
  }

  // Concatenate contiguous chunks from seq 0; once the frameUp header's declared
  // length is fully present, unframe and return the request payload.
  Uint8List? _complete(String session) {
    final chunks = _up[session]!;
    final out = <int>[];
    for (var seq = 0; chunks.containsKey(seq); seq++) {
      out.addAll(chunks[seq]!);
      if (out.length >= TxtQueryWire.frameHeader) {
        final declared = (out[0] << 8) | out[1];
        if (out.length >= TxtQueryWire.frameHeader + declared) {
          _up.remove(session);
          return TxtQueryWire.unframeUp(out);
        }
      }
    }
    return null;
  }

  void _handle(String session, Uint8List requestBytes) {
    var pos = 2; // skip 'G1'
    final method = requestBytes[pos++];
    final pathLen = (requestBytes[pos] << 8) | requestBytes[pos + 1];
    pos += 2;
    final path = utf8.decode(requestBytes.sublist(pos, pos + pathLen));
    pos += pathLen;
    final headerCount = requestBytes[pos++];
    for (var i = 0; i < headerCount; i++) {
      final nameLen = requestBytes[pos++];
      pos += nameLen;
      final valueLen = (requestBytes[pos] << 8) | requestBytes[pos + 1];
      pos += 2 + valueLen;
    }
    final body = Uint8List.sublistView(requestBytes, pos);

    final int status;
    final Uint8List responseBody;
    if (method == 2) {
      relay[path] = body;
      status = 200;
      responseBody = Uint8List(0);
    } else {
      final hit = relay[path];
      if (hit == null) {
        status = 404;
        responseBody = Uint8List(0);
      } else {
        status = 200;
        responseBody = hit;
      }
    }
    (_down[session] ??= <int>[]).addAll(_encodeResponse(status, responseBody));
  }

  // One poll pops up to the lane's downstream budget and re-queues the rest.
  Uint8List _nextDown(String session) {
    final buf = _down[session];
    if (buf == null || buf.isEmpty) {
      return TxtQueryWire.frameDown(const <int>[]);
    }
    final cap = TxtQueryWire.downstreamBudget - TxtQueryWire.frameHeader;
    final take = buf.length < cap ? buf.length : cap;
    final piece = Uint8List.fromList(buf.sublist(0, take));
    buf.removeRange(0, take);
    return TxtQueryWire.frameDown(piece);
  }

  Uint8List _encodeResponse(int status, Uint8List body) {
    final out = BytesBuilder(copy: false);
    out.add(const <int>[0x67, 0x31]); // 'g1'
    out.add(<int>[(status >> 8) & 0xFF, status & 0xFF]);
    final n = body.length;
    out.add(<int>[
      (n >> 24) & 0xFF,
      (n >> 16) & 0xFF,
      (n >> 8) & 0xFF,
      n & 0xFF,
    ]);
    out.add(body);
    return out.toBytes();
  }
}
