// SECTION ب — the `give` gateway, Dart (phone) side.
//
// A phone whose direct TCP to the relay is cut carries the SAME relay GET / PUT
// over the existing TXT lane (RFC 1035, test port 5300). This is the phone end
// of that lane: it frames one relay request into the give envelope, drives it up
// the lane with TxtQueryWire over a TxtQueryTransport, then polls the lane and
// drains the give response envelope by its declared body length.
//
// It holds no key and decodes no box — the body it carries is the opaque sealed
// box — and it never opens port 53, deploys a relay or invents a public domain.
// The byte layout below matches tools/t2/txt_give.py exactly:
//
//   request  (uplink, one session)
//       'G1' | method(1) | path_len(2) | path | hdr_count(1) |
//       [ name_len(1) name val_len(2) val ]* | body(rest)
//   response (downlink, queued once, drained over polls)
//       'g1' | status(2) | body_len(4) | body
//
// GET = 1, PUT = 2; the only header forwarded is x-broadcast-auth.

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:adaptive_transport/adaptive_transport.dart'
    show
        HostPort,
        ParsedDnsAnswer,
        TxtQueryTransport,
        TxtQueryWire,
        TxtQueryWireException,
        Udp53QueryTransport;
import 'package:broadcast/broadcast.dart'
    show BroadcastHttpResponse, BroadcastHttpTransport;

import 'relay_requests.dart' show RequestBudget, RequestBudgetSpent;

/// give request envelope magic (uplink), version 1 — 'G1'.
const List<int> _reqMagic = <int>[0x47, 0x31];

/// give response envelope magic (downlink), version 1 — 'g1'.
const List<int> _respMagic = <int>[0x67, 0x31];

const int _methodGet = 1;
const int _methodPut = 2;

/// The lane is narrow, so only the one header the sealed-letter protocol needs
/// rides along; anything else is dropped before the wire. Matches txt_give.py
/// FORWARD_HEADERS.
const String _forwardHeader = 'x-broadcast-auth';

/// Raised only when the TXT lane itself fails — a lost datagram, a refusal, a
/// truncated or unparsable answer, or a response the lane could not drain. A
/// give *status* (404 miss, 409 conflict, 502 relay-down) is an answer and is
/// returned, never thrown, so a [FallbackBroadcastTransport] catches only a
/// dead lane and not a real HTTP outcome.
class TxtLaneException implements Exception {
  const TxtLaneException(this.message);
  final String message;
  @override
  String toString() => 'TxtLaneException: $message';
}

List<int> _u16(int n) {
  if (n < 0 || n > 0xFFFF) throw TxtLaneException('$n does not fit u16');
  return <int>[(n >> 8) & 0xFF, n & 0xFF];
}

/// Encodes one relay request into the give uplink envelope.
Uint8List encodeGiveRequest(
  int method,
  String path,
  Map<String, String> headers,
  Uint8List body,
) {
  final out = BytesBuilder(copy: false);
  out.add(_reqMagic);
  out.addByte(method);
  final pathBytes = utf8.encode(path);
  out.add(_u16(pathBytes.length));
  out.add(pathBytes);
  final forwarded = <MapEntry<String, String>>[
    for (final e in headers.entries)
      if (e.key.toLowerCase() == _forwardHeader)
        MapEntry(e.key.toLowerCase(), e.value),
  ];
  out.addByte(forwarded.length);
  for (final e in forwarded) {
    final name = ascii.encode(e.key);
    final value = utf8.encode(e.value);
    out.addByte(name.length);
    out.add(name);
    out.add(_u16(value.length));
    out.add(value);
  }
  out.add(body);
  return out.toBytes();
}

/// The TXT-lane transport: every relay GET / PUT becomes one give round trip
/// over the lane. Throws [TxtLaneException] only when the lane itself fails, so
/// a [FallbackBroadcastTransport] can fall to it from HTTPS and, in turn, catch
/// a dead lane.
class TxtLaneBroadcastTransport implements BroadcastHttpTransport {
  TxtLaneBroadcastTransport({
    required this._transport,
    required this._domain,
    this._queryTimeout = const Duration(seconds: 4),
    this._drainTimeout = const Duration(seconds: 60),
    this._pollGap = const Duration(milliseconds: 20),
  });

  /// A UDP transport to the give gateway on [host]:[port] (the TXT lane test
  /// port, never 53).
  factory TxtLaneBroadcastTransport.udp({
    required String domain,
    String host = '127.0.0.1',
    int port = 5300,
    Duration queryTimeout = const Duration(seconds: 4),
    Duration drainTimeout = const Duration(seconds: 60),
  }) {
    if (port == 53) {
      throw const TxtLaneException(
        'the give lane uses the test port, never 53',
      );
    }
    return TxtLaneBroadcastTransport(
      transport: Udp53QueryTransport(HostPort(host: host, port: port)),
      domain: domain,
      queryTimeout: queryTimeout,
      drainTimeout: drainTimeout,
    );
  }

  final TxtQueryTransport _transport;
  final String _domain;
  final Duration _queryTimeout;
  final Duration _drainTimeout;
  final Duration _pollGap;
  final Random _txids = Random.secure();

  @override
  Future<BroadcastHttpResponse> get(Uri url) => _roundTrip(
    encodeGiveRequest(_methodGet, _relativePath(url), const {}, Uint8List(0)),
  );

  @override
  Future<BroadcastHttpResponse> put(
    Uri url,
    Uint8List body, {
    Map<String, String> headers = const {},
  }) => _roundTrip(
    encodeGiveRequest(_methodPut, _relativePath(url), headers, body),
  );

  Future<void> dispose() => _transport.dispose();

  /// Only the path and query reach the gateway; it refuses any scheme or host in
  /// the request, so this side never aims it anywhere but our own relay.
  String _relativePath(Uri url) {
    final path = url.path.isEmpty ? '/' : url.path;
    return url.query.isEmpty ? path : '$path?${url.query}';
  }

  Future<BroadcastHttpResponse> _roundTrip(Uint8List request) async {
    final encoded = TxtQueryWire.encodeQueries(request, _domain);
    final session = encoded.sessionId;

    // The uplink chunks go out in order; the responder reassembles by seq, so a
    // missing one is simply re-sent as the same seq. The last chunk's answer may
    // already carry the first downlink bytes.
    var buffer = Uint8List(0);
    for (final name in encoded.names) {
      buffer = _append(buffer, await _query(name));
    }

    int? total;
    final deadline = DateTime.now().add(_drainTimeout);
    while (true) {
      if (total == null && buffer.length >= 8) {
        if (buffer[0] != _respMagic[0] || buffer[1] != _respMagic[1]) {
          throw const TxtLaneException('downlink is not a give response');
        }
        total =
            8 +
            ((buffer[4] << 24) |
                (buffer[5] << 16) |
                (buffer[6] << 8) |
                buffer[7]);
      }
      if (total != null && buffer.length >= total) {
        final status = (buffer[2] << 8) | buffer[3];
        final body = Uint8List.sublistView(buffer, 8, total);
        return BroadcastHttpResponse(statusCode: status, body: body);
      }
      if (DateTime.now().isAfter(deadline)) {
        throw TxtLaneException(
          'give response incomplete: have=${buffer.length} want=$total',
        );
      }
      final chunk = await _query(_pollName(session));
      if (chunk.isEmpty) {
        await Future<void>.delayed(_pollGap);
      } else {
        buffer = _append(buffer, chunk);
      }
    }
  }

  String _pollName(String session) => TxtQueryWire.buildQueryName(
    const <int>[],
    TxtQueryWire.seqMax,
    session,
    TxtQueryWire.newNonce(),
    _domain,
  );

  /// One DNS query over the lane, returning the (unframed) bytes its TXT answer
  /// carried. Mirrors TxtQueryLane._query: random txid, validate txid + question
  /// name + rcode, then unframe. Any failure here means the lane is not working.
  Future<Uint8List> _query(String name) async {
    final txid = _txids.nextInt(0x10000);
    final packet = TxtQueryWire.buildDnsQueryPacket(txid, name);
    final Uint8List response;
    try {
      response = await _transport.exchange(packet, txid, _queryTimeout);
    } catch (e) {
      throw TxtLaneException('lane exchange failed: $e');
    }
    final ParsedDnsAnswer answer;
    try {
      answer = TxtQueryWire.parseDnsAnswerPacket(response);
    } on TxtQueryWireException catch (e) {
      throw TxtLaneException('unparsable answer: $e');
    }
    if (answer.txid != txid) {
      throw TxtLaneException('answer txid ${answer.txid} != $txid');
    }
    final qn = answer.questionName;
    if (qn != null && qn != name) {
      throw TxtLaneException('answer question "$qn" != "$name"');
    }
    final carried = answer.payload;
    if (answer.rcode != TxtQueryWire.rcodeNoError || carried == null) {
      throw TxtLaneException('rcode=${answer.rcode}');
    }
    try {
      return TxtQueryWire.unframeDown(carried);
    } on TxtQueryWireException {
      // An answer that is not framed is still an answer.
      return carried;
    }
  }

  Uint8List _append(Uint8List a, Uint8List b) {
    if (b.isEmpty) return a;
    final out = Uint8List(a.length + b.length);
    out.setAll(0, a);
    out.setAll(a.length, b);
    return out;
  }
}

/// HTTPS first; on a *thrown* failure (the relay is unreachable) the same
/// GET / PUT goes over the TXT lane. A network once seen to need the lane is
/// remembered, so the next request on it skips the HTTPS timeout.
class FallbackBroadcastTransport implements BroadcastHttpTransport {
  FallbackBroadcastTransport({
    required this._https,
    required this._txt,
    String Function()? networkId,
    bool Function(Object error)? fallsBackOn,
  }) : _networkId = networkId ?? (() => 'default'),
       _fallsBackOn = fallsBackOn ?? ((_) => true);

  final BroadcastHttpTransport _https;
  final BroadcastHttpTransport _txt;
  final String Function() _networkId;

  /// Which HTTPS failures mean "the relay is unreachable from here". A refusal
  /// that is this install's own (its daily allowance spent) is not one: the
  /// lane must not become a way around it.
  final bool Function(Object error) _fallsBackOn;
  final Set<String> _txtNetworks = <String>{};

  /// Whether [network] is remembered as one where HTTPS failed and the lane now
  /// carries the traffic.
  bool prefersTxt(String network) => _txtNetworks.contains(network);

  @override
  Future<BroadcastHttpResponse> get(Uri url) => _run((t) => t.get(url));

  @override
  Future<BroadcastHttpResponse> put(
    Uri url,
    Uint8List body, {
    Map<String, String> headers = const {},
  }) => _run((t) => t.put(url, body, headers: headers));

  Future<BroadcastHttpResponse> _run(
    Future<BroadcastHttpResponse> Function(BroadcastHttpTransport) op,
  ) async {
    final network = _networkId();
    if (_txtNetworks.contains(network)) {
      return op(_txt);
    }
    try {
      return await op(_https);
    } catch (error) {
      if (!_fallsBackOn(error)) rethrow;
      _txtNetworks.add(network);
      return op(_txt);
    }
  }
}

/// The lane under the same daily allowance as HTTPS: a give round trip is
/// still one relay request. Every request it carries is reported with its
/// method, status, size and time, so the journal can say via=txt.
class MeteredTxtTransport implements BroadcastHttpTransport {
  MeteredTxtTransport({
    required this.lane,
    required this.budget,
    this.onCarried,
  });

  final BroadcastHttpTransport lane;
  final RequestBudget budget;
  final void Function(String method, int status, int bytes, Duration open)?
  onCarried;

  @override
  Future<BroadcastHttpResponse> get(Uri url) =>
      _send('GET', 0, () => lane.get(url));

  @override
  Future<BroadcastHttpResponse> put(
    Uri url,
    Uint8List body, {
    Map<String, String> headers = const {},
  }) => _send('PUT', body.length, () => lane.put(url, body, headers: headers));

  Future<BroadcastHttpResponse> _send(
    String method,
    int sent,
    Future<BroadcastHttpResponse> Function() op,
  ) async {
    if (!budget.take(write: method == 'PUT')) throw const RequestBudgetSpent();
    final open = Stopwatch()..start();
    var status = -1;
    var bytes = sent;
    try {
      final response = await op();
      status = response.statusCode;
      if (method == 'GET') bytes = response.body?.length ?? 0;
      return response;
    } finally {
      open.stop();
      budget.done(open.elapsed);
      onCarried?.call(method, status, bytes, open.elapsed);
    }
  }
}
