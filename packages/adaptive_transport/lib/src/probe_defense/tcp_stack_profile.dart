/// OS TCP/IP stack profiles, for making the packet layer agree with the
/// TLS layer.
///
/// A hello that claims Safari 17 riding on a socket whose SYN carries a
/// Linux initial TTL and a Linux window is a contradiction visible to any
/// passive fingerprinter (p0f and its descendants), and no amount of TLS
/// realism repairs it. This module names the observables and applies the
/// ones a userspace process can actually set.
///
/// What is honestly reachable, and what is not:
///
/// | observable        | settable from Dart | how                        |
/// |-------------------|--------------------|----------------------------|
/// | initial TTL       | yes                | `IP_TTL` / `IPV6_UNICAST_HOPS` |
/// | TCP_NODELAY       | yes                | `SocketOption.tcpNoDelay`  |
/// | MSS               | Linux only         | `TCP_MAXSEG` before connect |
/// | window size       | indirectly         | `SO_RCVBUF` (the kernel scales it) |
/// | window scale      | no                 | kernel-wide sysctl         |
/// | SACK permitted    | no                 | kernel-wide sysctl         |
/// | option *order*    | no                 | fixed by the kernel        |
///
/// So [TcpStackProfile] is two things at once: the settings that are
/// applied, and a declaration of the rest, which is what
/// [TcpStackProfile.unreachableObservables] reports. A deployment that
/// needs byte-exact SYN matching must reach below the VM — a host sysctl
/// profile, a network namespace, or a native socket layer behind
/// [TcpSocketTuner]. Pretending otherwise in code comments would be the
/// worst outcome: a system believed hardened that is not.
library;

import 'dart:io';

/// The OS stacks we can impersonate.
enum TcpStackProfileId { iOS, android, windows, linux }

/// A named set of TCP/IP stack observables.
class TcpStackProfile {
  const TcpStackProfile({
    required this.id,
    required this.initialTtl,
    required this.windowSize,
    required this.maximumSegmentSize,
    required this.windowScale,
    required this.sackPermitted,
    required this.timestampsEnabled,
  });

  final TcpStackProfileId id;

  /// Initial IP TTL (`ttl` in a p0f signature). The classic tells: 64 on
  /// Linux and Apple platforms, 128 on Windows.
  final int initialTtl;

  /// Advertised receive window in the SYN.
  final int windowSize;

  /// MSS the SYN advertises, for an ordinary 1500-byte-MTU path.
  final int maximumSegmentSize;

  /// TCP window scale shift count.
  final int windowScale;

  final bool sackPermitted;
  final bool timestampsEnabled;

  static const TcpStackProfile iOS = TcpStackProfile(
    id: TcpStackProfileId.iOS,
    initialTtl: 64,
    windowSize: 65535,
    maximumSegmentSize: 1460,
    windowScale: 6,
    sackPermitted: true,
    timestampsEnabled: true,
  );

  static const TcpStackProfile android = TcpStackProfile(
    id: TcpStackProfileId.android,
    initialTtl: 64,
    windowSize: 65535,
    maximumSegmentSize: 1460,
    windowScale: 8,
    sackPermitted: true,
    timestampsEnabled: true,
  );

  static const TcpStackProfile windows = TcpStackProfile(
    id: TcpStackProfileId.windows,
    initialTtl: 128,
    windowSize: 64240,
    maximumSegmentSize: 1460,
    windowScale: 8,
    sackPermitted: true,
    timestampsEnabled: false,
  );

  static const TcpStackProfile linux = TcpStackProfile(
    id: TcpStackProfileId.linux,
    initialTtl: 64,
    windowSize: 64240,
    maximumSegmentSize: 1460,
    windowScale: 7,
    sackPermitted: true,
    timestampsEnabled: true,
  );

  static const List<TcpStackProfile> all = [iOS, android, windows, linux];

  static TcpStackProfile forId(TcpStackProfileId id) => switch (id) {
    TcpStackProfileId.iOS => iOS,
    TcpStackProfileId.android => android,
    TcpStackProfileId.windows => windows,
    TcpStackProfileId.linux => linux,
  };

  /// Look-up by the lower-case name a [UtlsClientProfile] carries.
  static TcpStackProfile? byName(String name) {
    for (final profile in all) {
      if (profile.id.name.toLowerCase() == name.toLowerCase()) return profile;
    }
    return null;
  }

  /// The p0f-style signature this profile is trying to present, in that
  /// tool's own notation, so a deployment can diff it against a capture.
  String get p0fSignature =>
      '$initialTtl:$windowSize,$windowScale:'
      'mss=$maximumSegmentSize:'
      '${sackPermitted ? 'sok' : '-'},'
      '${timestampsEnabled ? 'ts' : '-'}';

  /// Observables this profile declares but a userspace Dart process cannot
  /// set on the current platform. Empty is not achievable today on any
  /// platform; callers should surface this, not swallow it.
  List<String> get unreachableObservables => [
    if (!Platform.isLinux) 'mss',
    'window_size',
    'window_scale',
    'sack_permitted',
    'timestamps',
    'option_order',
  ];
}

/// Applies what is applicable of a [TcpStackProfile] to a socket.
///
/// Kept behind an interface so tests can assert the calls, and so a native
/// implementation can replace it without touching callers.
abstract class TcpSocketTuner {
  /// Applies [profile] to [socket], returning the observables actually set.
  Future<List<String>> apply(RawSocket socket, TcpStackProfile profile);
}

/// The tuner that uses the socket options `dart:io` exposes.
class DartIoTcpSocketTuner implements TcpSocketTuner {
  const DartIoTcpSocketTuner({this.onOptionRefused});

  /// Called once per option the platform refused, with the option's name
  /// and the reason given.
  ///
  /// A refusal is reported rather than thrown: sandboxes and unprivileged
  /// processes legitimately deny these, and the connection stays usable
  /// with a less faithful profile. But it is never silent — a caller that
  /// cannot see the denial cannot tell a real profile from a nominal one.
  final void Function(String option, String reason)? onOptionRefused;

  /// `IPPROTO_IP` / `IP_TTL`. Linux uses option 2; BSD-derived systems
  /// (macOS, iOS) and Winsock use 4 — on those, option 2 at the IPv4 level
  /// is `IP_HDRINCL`, an entirely different setting, so the constant must
  /// follow the platform.
  static int get _ipTtlOption => Platform.isLinux || Platform.isAndroid ? 2 : 4;

  /// `IPPROTO_IPV6` / `IPV6_UNICAST_HOPS`. 16 on Linux, 4 on BSD/macOS and
  /// on Winsock.
  static int get _ipv6HopLimitOption =>
      Platform.isLinux || Platform.isAndroid ? 16 : 4;

  /// `IPPROTO_TCP` / `TCP_MAXSEG`. Linux-family only: macOS exposes it
  /// read-mostly and Windows has no equivalent.
  static const int _tcpMaxSegOption = 2;

  /// `SOL_SOCKET` / `SO_RCVBUF`. 8 on Linux, 0x1002 on BSD/macOS and on
  /// Winsock.
  static int get _receiveBufferOption =>
      Platform.isLinux || Platform.isAndroid ? 8 : 0x1002;

  static bool get _isLinuxFamily => Platform.isLinux || Platform.isAndroid;

  @override
  Future<List<String>> apply(RawSocket socket, TcpStackProfile profile) async {
    final applied = <String>[];

    void set(String name, int level, int option, int value) {
      try {
        socket.setRawOption(RawSocketOption.fromInt(level, option, value));
        applied.add(name);
      } on OSError catch (e) {
        onOptionRefused?.call(name, e.message);
      } on SocketException catch (e) {
        // A socket closed under us — the caller's connection is gone, but
        // that is the caller's problem to notice, not a reason to fail
        // here with a different exception than every other refusal.
        onOptionRefused?.call(name, e.message);
      } on ArgumentError catch (e) {
        onOptionRefused?.call(name, '${e.message}');
      }
    }

    final isIpv6 = socket.address.type == InternetAddressType.IPv6;
    set(
      'initial_ttl',
      isIpv6 ? RawSocketOption.levelIPv6 : RawSocketOption.levelIPv4,
      isIpv6 ? _ipv6HopLimitOption : _ipTtlOption,
      profile.initialTtl,
    );

    if (_isLinuxFamily) {
      set(
        'mss',
        RawSocketOption.levelTcp,
        _tcpMaxSegOption,
        profile.maximumSegmentSize,
      );
    }

    // The receive buffer is the only lever on the advertised window, and
    // the kernel doubles and rounds it — so this nudges the window toward
    // the profile rather than setting it.
    set(
      'receive_buffer',
      RawSocketOption.levelSocket,
      _receiveBufferOption,
      profile.windowSize,
    );

    return applied;
  }
}

/// A tuner that records calls and changes nothing — for tests and for
/// platforms where socket options are unavailable.
class RecordingTcpSocketTuner implements TcpSocketTuner {
  final List<TcpStackProfile> appliedProfiles = [];

  @override
  Future<List<String>> apply(RawSocket socket, TcpStackProfile profile) async {
    appliedProfiles.add(profile);
    return const ['initial_ttl'];
  }
}
