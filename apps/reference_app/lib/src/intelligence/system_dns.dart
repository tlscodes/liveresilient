/// This device's own DNS resolver, read from the platform's own system
/// API over one method channel — the address the OS itself already
/// sends this connection's DNS queries to. iOS answers from libresolv's
/// `res_9_getservers` (first entry, `SystemDnsReader` in
/// AppDelegate.swift); Android from
/// `ConnectivityManager.getLinkProperties(activeNetwork).dnsServers`
/// (first entry, MainActivity.kt). Nothing is probed, scanned or
/// downloaded: this is a read of configuration, and [SystemDns.refresh]
/// is the only call.
///
/// Desktop and the test gate have no channel: the call fails, [current]
/// stays null, and `systemDnsResolverBinding` adds nothing — today's
/// behaviour, unchanged.
library;

import 'package:adaptive_transport/adaptive_transport.dart' show HostPort;
import 'package:flutter/services.dart';

class SystemDns {
  SystemDns({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(channelName);

  /// Must match `SystemDnsReader.channelName` (AppDelegate.swift) and
  /// `SYSTEM_DNS_CHANNEL` (MainActivity.kt).
  static const String channelName = 'com.tlscodes.reference_app/system_dns';

  final MethodChannel _channel;
  HostPort? _current;

  /// The last answer, for the synchronous seam `defaultBorderRelayEndpoints`
  /// reads when the letter's lanes open — null until [refresh] has found
  /// one, and null again after a refresh that found none.
  HostPort? get current => _current;

  /// Asks the platform once. No channel (desktop, tests), no resolver on
  /// the active link, or any error → null: never a crash, and never a
  /// stale address kept past a network that no longer names it.
  Future<HostPort?> refresh() async {
    try {
      final host = (await _channel.invokeMethod<String>(
        'firstResolver',
      ))?.trim();
      return _current = host == null || host.isEmpty
          ? null
          : HostPort(host: host, port: 53);
    } catch (_) {
      return _current = null;
    }
  }
}

/// The one reader: refreshed at boot and on every resume (main.dart),
/// read by `defaultBorderRelayEndpoints` when the letter's lanes open.
final SystemDns systemDns = SystemDns();
