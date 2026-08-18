/// DataChannelPort over a raw UDP socket — the fountain video lane's
/// transport for lossy rows (RIG_GUIDE §0.3 step 2).
///
/// WHY: two measured official loss60 runs proved the SCTP data channel
/// clocks down to ~2 packets/s under 60% bidirectional loss regardless of
/// maxRetransmits:0 — the transport's own recovery machinery is the
/// ceiling. The rateless lane needs a datagram path with NO loss-reactive
/// control underneath; rate governance belongs to the lane alone
/// (delivery-clocked bucket + hard cap). This port is that path: plain
/// UDP to the rig's dumb datagram relay on the Mac, phone -> Mac -> phone,
/// both crossings shaped — the same physics as force-relay media.
///
/// Deliberately NO reliability logic here: the fountain lane is the
/// intelligence against loss/duplication/reordering. This port only
/// prefixes/strips the relay's 16-byte room key and keeps the seat warm.
///
/// ROOM KEY, documented deviation from RIG_GUIDE §0.3's "transferId": the
/// key is derived from the callId string (deterministic pad/truncate), not
/// the content sha prefix — the relay only needs an opaque shared key, the
/// inner fountain frames still carry the content-addressed transferId, and
/// this keeps the app free of a crypto dependency. Both ports are built by
/// the same test code in one process, so derivation drift is impossible.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:messaging/messaging.dart';

const int _keyBytes = 16;

/// Registration/keepalive cadence. Pre-HELLO it bootstraps the relay's two
/// seats (each registration crosses the shaped bridge once, so under heavy
/// loss a few tries are expected); afterwards it keeps the receiver's seat
/// fresh — the receiver sends nothing on its own until HELLO decodes, and
/// a silent seat is what the relay's LRU eviction targets.
const Duration _keepalive = Duration(seconds: 1);

final class DatagramLanePort implements DataChannelPort {
  DatagramLanePort._(this._socket, this._relayHost, this._relayPort, this._key) {
    _socket.writeEventsEnabled = false;
    _sub = _socket.listen(_onEvent);
    _socket.send(_key, _relayHost, _relayPort);
    _keepaliveTimer = Timer.periodic(_keepalive, (_) {
      _socket.send(_key, _relayHost, _relayPort);
    });
  }

  /// [roomKey] must be exactly 16 bytes and shared by exactly the two ports
  /// of one lane. [relayHost] must be an address literal (the rig always
  /// passes one) — no per-send DNS.
  static Future<DatagramLanePort> bind({
    required String relayHost,
    required int relayPort,
    required List<int> roomKey,
  }) async {
    if (roomKey.length != _keyBytes) {
      throw ArgumentError.value(roomKey, 'roomKey', 'must be 16 bytes');
    }
    final host = InternetAddress.tryParse(relayHost);
    if (host == null) {
      throw ArgumentError.value(relayHost, 'relayHost', 'must be an IP literal');
    }
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    return DatagramLanePort._(
      socket,
      host,
      relayPort,
      Uint8List.fromList(roomKey),
    );
  }

  /// Deterministic 16-byte room key from a call id (pad with the id's own
  /// bytes cycled; zero-pad an empty id defensively).
  static Uint8List roomKeyFromCallId(String callId) {
    final bytes = callId.codeUnits;
    final key = Uint8List(_keyBytes);
    if (bytes.isEmpty) return key;
    for (var i = 0; i < _keyBytes; i++) {
      key[i] = bytes[i % bytes.length] & 0xFF;
    }
    return key;
  }

  final RawDatagramSocket _socket;
  final InternetAddress _relayHost;
  final int _relayPort;
  final Uint8List _key;
  final _inbound = StreamController<List<int>>.broadcast();
  late final StreamSubscription<RawSocketEvent> _sub;
  late final Timer _keepaliveTimer;
  var _closed = false;

  /// Evidence counters (same discipline as the lanes: a dead row must name
  /// its starving leg from the summary, not from guesswork).
  int sentDatagrams = 0;
  int localSendDrops = 0;
  int receivedDatagrams = 0;

  @override
  Stream<List<int>> get inbound => _inbound.stream;

  void _onEvent(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    // Drain fully: one read event may cover several queued datagrams.
    for (var d = _socket.receive(); d != null; d = _socket.receive()) {
      final data = d.data;
      if (data.length <= _keyBytes) continue; // echo/registration noise
      var mine = true;
      for (var i = 0; i < _keyBytes; i++) {
        if (data[i] != _key[i]) {
          mine = false;
          break;
        }
      }
      if (!mine) continue;
      receivedDatagrams++;
      if (!_inbound.isClosed) {
        _inbound.add(Uint8List.sublistView(data, _keyBytes));
      }
    }
  }

  @override
  Future<void> send(List<int> frame) async {
    if (_closed) return;
    final out = Uint8List(_keyBytes + frame.length)
      ..setRange(0, _keyBytes, _key)
      ..setRange(_keyBytes, _keyBytes + frame.length, frame);
    var sent = _socket.send(out, _relayHost, _relayPort);
    if (sent == 0) {
      // Would-block: the tiny default UDP send buffer met a bucket burst.
      // One short breath and one retry, then it is an honest local drop —
      // the lane is loss-tolerant by design and must never queue here.
      await Future<void>.delayed(const Duration(milliseconds: 3));
      sent = _socket.send(out, _relayHost, _relayPort);
      if (sent == 0) {
        localSendDrops++;
        return;
      }
    }
    sentDatagrams++;
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _keepaliveTimer.cancel();
    await _sub.cancel();
    _socket.close();
    await _inbound.close();
  }
}
