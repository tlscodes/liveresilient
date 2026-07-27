import 'dart:io';
import 'dart:typed_data';

import 'package:adaptive_transport/adaptive_transport.dart';
import 'package:test/test.dart';

/// Exercises the profile-carrying connect path against a loopback server.
///
/// Which options a sandbox permits varies, so these assert the wiring —
/// the tuner runs, its result reaches the caller, and the raw socket
/// behaves as a duplex stream — not that any particular option was
/// accepted by the kernel running the test.
void main() {
  late ServerSocket server;
  late List<Socket> accepted;

  setUp(() async {
    accepted = [];
    server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    server.listen(accepted.add);
  });

  tearDown(() async {
    for (final socket in accepted) {
      socket.destroy();
    }
    await server.close();
  });

  test('a profile-less connect still uses the plain socket path', () async {
    final stream = await connectFallbackSocket(server.address.host, server.port);
    addTearDown(stream.close);
    expect(stream, isA<SocketDuplexStream>());
  });

  test('a profile reaches the tuner and the applied list reaches the caller',
      () async {
    final tuner = RecordingTcpSocketTuner();
    List<String>? applied;

    final stream = await connectFallbackSocket(
      server.address.host,
      server.port,
      profile: TcpStackProfile.forId(TcpStackProfileId.linux),
      tuner: tuner,
      onProfileApplied: (a) => applied = a,
    );
    addTearDown(stream.close);

    expect(stream, isA<RawSocketDuplexStream>());
    expect(tuner.appliedProfiles, hasLength(1));
    expect(tuner.appliedProfiles.single.id, TcpStackProfileId.linux);
    expect(applied, isNotNull);
  });

  test('the raw-socket stream carries bytes to the peer', () async {
    final stream = await connectFallbackSocket(
      server.address.host,
      server.port,
      profile: TcpStackProfile.forId(TcpStackProfileId.linux),
      tuner: RecordingTcpSocketTuner(),
    );
    addTearDown(stream.close);

    stream.add(Uint8List.fromList([7, 8, 9]));

    // Give the loopback round trip a chance to complete.
    final peer = await _firstAccepted(() => accepted);
    final received = await peer.first;
    expect(received, [7, 8, 9]);
  });

  test('a refused option is reported, not swallowed', () async {
    final refusals = <String, String>{};
    final raw = await RawSocket.connect(server.address.host, server.port);
    raw.close();

    // Every option on a closed socket is refused, so each refusal must
    // surface through the callback with the reason the platform gave.
    final applied = await DartIoTcpSocketTuner(
      onOptionRefused: (option, reason) => refusals[option] = reason,
    ).apply(raw, TcpStackProfile.forId(TcpStackProfileId.linux));

    expect(applied, isEmpty);
    expect(refusals, isNotEmpty);
    expect(refusals.keys, contains('initial_ttl'));
    expect(refusals.values, everyElement(isNotEmpty));
  });
}

Future<Socket> _firstAccepted(List<Socket> Function() accepted) async {
  for (var i = 0; i < 100; i++) {
    if (accepted().isNotEmpty) return accepted().first;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  throw StateError('no connection was accepted');
}
