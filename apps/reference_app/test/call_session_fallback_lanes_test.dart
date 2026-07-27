/// Proves the resilient fallback stack is registered with the session's
/// fabric at build time, not only in the transport package's own tests.
///
/// Endpoints point at loopback ports nothing is listening on: registration
/// is what is under test, and a lane's health is allowed to be bad. No
/// traffic leaves the machine.
library;

import 'dart:io';

import 'package:adaptive_transport/adaptive_transport.dart';
import 'package:call_core/call_core.dart';
import 'package:connection_orchestrator/connection_orchestrator.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reference_app/src/call_session.dart';

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('fallback_lanes_test');
  });

  tearDown(() => dir.deleteSync(recursive: true));

  CallSessionHandle build({
    required String callId,
    ResilientLaneEndpoints lanes = const ResilientLaneEndpoints(),
  }) => buildWebRtcCallSession(
    endpoint: Uri.parse('wss://localhost:0/'),
    callId: callId,
    role: CallRole.initiator,
    storageDirFactory: () => dir,
    fallbackLanes: lanes,
  );

  test('every configured fallback lane is registered alongside WebRTC', () {
    final session = build(
      callId: 'all-lanes',
      lanes: ResilientLaneEndpoints(
        udpRemote: const HostPort(host: '127.0.0.1', port: 9),
        relayUri: Uri.parse('wss://127.0.0.1:9/relay'),
        longPollUri: Uri.parse('https://127.0.0.1:9/poll'),
        meshSender: (_) async => const SendResult(SendStatus.unavailable),
      ),
    );

    final ids = session.connectionFabric!.snapshot.lanes
        .map((lane) => lane.id)
        .toSet();

    expect(ids, contains('webrtc-media'));
    expect(ids, contains(ResilientLaneIds.primaryUdp));
    expect(ids, contains(ResilientLaneIds.webSocketRelay));
    expect(ids, contains(ResilientLaneIds.httpLongPoll));
    expect(ids, contains(ResilientLaneIds.localMesh));
  });

  test('an unconfigured lane is absent rather than aimed at nowhere', () {
    final session = build(
      callId: 'relay-only',
      lanes: ResilientLaneEndpoints(
        relayUri: Uri.parse('wss://127.0.0.1:9/relay'),
      ),
    );

    final ids = session.connectionFabric!.snapshot.lanes
        .map((lane) => lane.id)
        .toSet();

    expect(ids, contains(ResilientLaneIds.webSocketRelay));
    expect(ids, isNot(contains(ResilientLaneIds.primaryUdp)));
    expect(ids, isNot(contains(ResilientLaneIds.httpLongPoll)));
    expect(ids, isNot(contains(ResilientLaneIds.localMesh)));
  });

  test('with no fallback endpoints the session still builds on WebRTC', () {
    final session = build(callId: 'no-fallback');

    final ids = session.connectionFabric!.snapshot.lanes
        .map((lane) => lane.id)
        .toSet();

    expect(ids, {'webrtc-media'});
  });
}
