/// [MediaDataChannel] over the `flutter_webrtc` plugin's RTCDataChannel.
///
/// Same thin-adapter doctrine as the peer-connection port: 1:1 mapping,
/// zero policy. Reliability/ack/dedup live in the messaging layer; this
/// file only moves bytes and states across the plugin boundary.
///
/// | MediaDataChannel        | flutter_webrtc                                |
/// |-------------------------|-----------------------------------------------|
/// | (creation)              | pc.createDataChannel(label, RTCDataChannelInit|
/// |                         |   ..negotiated=true ..id ..ordered            |
/// |                         |   ..binaryType='binary')                      |
/// | state                   | RTCDataChannel.onDataChannelState             |
/// | inbound                 | RTCDataChannel.onMessage (binary or text —    |
/// |                         |   text arrives as UTF-8 bytes)                |
/// | send(frame)             | channel.send(RTCDataChannelMessage.fromBinary)|
/// | close                   | channel.close()                               |
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:media_webrtc/media_webrtc.dart';

/// Maps the plugin's channel state onto the pure-Dart enum. Total: every
/// plugin state has a mapping, so this never returns null.
MediaDataChannelState mapDataChannelState(rtc.RTCDataChannelState state) {
  return switch (state) {
    rtc.RTCDataChannelState.RTCDataChannelConnecting =>
      MediaDataChannelState.connecting,
    rtc.RTCDataChannelState.RTCDataChannelOpen => MediaDataChannelState.open,
    rtc.RTCDataChannelState.RTCDataChannelClosing =>
      MediaDataChannelState.closing,
    rtc.RTCDataChannelState.RTCDataChannelClosed =>
      MediaDataChannelState.closed,
  };
}

/// Converts a plugin message to raw frame bytes. Binary passes through;
/// a text message (some platform paths deliver text) arrives as its UTF-8
/// encoding, so the wire codec sees identical bytes either way.
List<int> frameBytesFromMessage(rtc.RTCDataChannelMessage message) {
  return message.isBinary ? message.binary : utf8.encode(message.text);
}

final class FlutterWebRtcDataChannel implements MediaDataChannel {
  FlutterWebRtcDataChannel(this._channel, this.label) {
    _channel.onDataChannelState = (rtc.RTCDataChannelState state) {
      // _lastState updates before the isClosed guard so a state ingested
      // during teardown still reaches currentState.
      _lastState = mapDataChannelState(state);
      if (_stateController.isClosed) return;
      _stateController.add(_lastState);
    };
    _channel.onMessage = (rtc.RTCDataChannelMessage message) {
      if (_inboundController.isClosed) return;
      _inboundController.add(frameBytesFromMessage(message));
    };
  }

  final rtc.RTCDataChannel _channel;

  @override
  final String label;

  final _stateController = StreamController<MediaDataChannelState>.broadcast();
  final _inboundController = StreamController<List<int>>.broadcast();
  var _closed = false;
  var _lastState = MediaDataChannelState.connecting;

  @override
  Stream<MediaDataChannelState> get state => _stateController.stream;

  @override
  MediaDataChannelState get currentState {
    // After close() the plugin field freezes (its event subscription is
    // cancelled), so the frozen value would misreport an open channel.
    if (_closed) return MediaDataChannelState.closed;
    final live = _channel.state;
    return live != null ? mapDataChannelState(live) : _lastState;
  }

  @override
  Stream<List<int>> get inbound => _inboundController.stream;

  @override
  int? get bufferedAmount => _channel.bufferedAmount;

  @override
  Future<void> send(List<int> frame) async {
    if (_closed) throw StateError('send after close');
    await _channel.send(
      rtc.RTCDataChannelMessage.fromBinary(Uint8List.fromList(frame)),
    );
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _channel.onDataChannelState = null;
    _channel.onMessage = null;
    await _channel.close();
    await _stateController.close();
    await _inboundController.close();
  }
}
