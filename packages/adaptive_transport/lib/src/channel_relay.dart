import 'dart:typed_data';

import 'package:clock/clock.dart';

import 'host_port.dart';

/// Thrown when data is sent toward a peer with no live TURN permission
/// (RFC 8656 section 9: the server drops such traffic; failing loudly on the
/// client is strictly better than a silent black hole).
class PermissionNotInstalledException implements Exception {
  PermissionNotInstalledException(this.peer);
  final HostPort peer;
  @override
  String toString() => 'PermissionNotInstalledException: $peer';
}

/// One bound TURN channel (RFC 8656 section 12): a 0x4000-0x7FFF channel
/// number tied to one peer, wrapping datagrams in the 4-byte ChannelData
/// header instead of a ~36-byte Send/Data indication.
class ChannelRelayLink {
  ChannelRelayLink._(this.channelNumber, this.peer, this._binder);

  final int channelNumber;
  final HostPort peer;
  final ChannelRelayBinder _binder;

  /// Send indication overhead this framing replaces: 20-byte STUN header +
  /// XOR-PEER-ADDRESS (12 for IPv4) + DATA attribute header (4).
  static const int sendIndicationOverheadBytes = 36;
  static const int headerBytes = 4;

  /// ChannelData framing (RFC 8656 section 12.4): u16 channel number,
  /// u16 length, payload, padded to a 4-byte boundary for stream transports.
  Uint8List wrap(Uint8List data) {
    _binder._requireLive(this);
    final padded = (data.length + 3) & ~3;
    final out = Uint8List(headerBytes + padded);
    final view = ByteData.sublistView(out);
    view.setUint16(0, channelNumber);
    view.setUint16(2, data.length);
    out.setRange(headerBytes, headerBytes + data.length, data);
    return out;
  }

  /// Reverses [wrap]; rejects frames for a different channel.
  Uint8List unwrap(Uint8List frame) {
    if (frame.length < headerBytes) {
      throw FormatException('ChannelData shorter than $headerBytes bytes');
    }
    final view = ByteData.sublistView(frame);
    final number = view.getUint16(0);
    if (number != channelNumber) {
      throw FormatException(
        'frame for channel 0x${number.toRadixString(16)}, '
        'this link is 0x${channelNumber.toRadixString(16)}',
      );
    }
    final length = view.getUint16(2);
    if (headerBytes + length > frame.length) {
      throw const FormatException('ChannelData length exceeds the frame');
    }
    return Uint8List.sublistView(frame, headerBytes, headerBytes + length);
  }
}

/// Manages TURN channel bindings and peer permissions with RFC 8656
/// lifetimes: permissions last 300 s (section 9.3), channel bindings 600 s
/// (section 12.2), and both are re-armed by [refresh].
class ChannelRelayBinder {
  ChannelRelayBinder({
    this.permissionLifetime = const Duration(seconds: 300),
    this.channelLifetime = const Duration(seconds: 600),
  });

  final Duration permissionLifetime;
  final Duration channelLifetime;

  static const int firstChannel = 0x4000;
  static const int lastChannel = 0x7FFF;

  final Map<String, DateTime> _permissionExpiry = {};
  final Map<String, ChannelRelayLink> _links = {};
  final Map<String, DateTime> _channelExpiry = {};
  int _nextChannel = firstChannel;

  int get boundChannelCount => _links.length;

  /// Installs (or re-arms) a permission for the peer's IP — the
  /// CreatePermission step every relayed destination needs first.
  void installPermission(HostPort peer) {
    _permissionExpiry[peer.host] = clock.now().add(permissionLifetime);
  }

  bool hasPermission(HostPort peer) {
    final expiry = _permissionExpiry[peer.host];
    return expiry != null && clock.now().isBefore(expiry);
  }

  /// Binds (or returns the existing) channel for [peer]. A ChannelBind also
  /// installs the permission (RFC 8656 section 12.2).
  ChannelRelayLink bind(HostPort peer) {
    installPermission(peer);
    final key = peer.authority;
    final existing = _links[key];
    if (existing != null) {
      _channelExpiry[key] = clock.now().add(channelLifetime);
      return existing;
    }
    if (_nextChannel > lastChannel) {
      throw StateError('channel number space 0x4000-0x7FFF exhausted');
    }
    final link = ChannelRelayLink._(_nextChannel++, peer, this);
    _links[key] = link;
    _channelExpiry[key] = clock.now().add(channelLifetime);
    return link;
  }

  /// Re-arms the binding and permission for [link] before they lapse.
  void refresh(ChannelRelayLink link) {
    installPermission(link.peer);
    _channelExpiry[link.peer.authority] = clock.now().add(channelLifetime);
  }

  /// Bindings due for a refresh within [margin].
  List<ChannelRelayLink> dueForRefresh(Duration margin) {
    final deadline = clock.now().add(margin);
    return [
      for (final e in _links.entries)
        if (!_channelExpiry[e.key]!.isAfter(deadline)) e.value,
    ];
  }

  void _requireLive(ChannelRelayLink link) {
    if (!hasPermission(link.peer)) {
      throw PermissionNotInstalledException(link.peer);
    }
    final expiry = _channelExpiry[link.peer.authority];
    if (expiry == null || !clock.now().isBefore(expiry)) {
      throw StateError('channel binding for ${link.peer} expired');
    }
  }
}
