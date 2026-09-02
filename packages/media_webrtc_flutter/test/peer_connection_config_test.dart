import 'package:flutter_test/flutter_test.dart';
import 'package:media_webrtc_flutter/src/flutter_webrtc_peer_connection_port.dart';

/// `createPeerConnection` needs a device, so the config it would be handed is
/// built by a pure function and asserted here instead. This is the test that
/// would have caught the original bug: every call was placed with an empty ICE
/// server list because nothing ever passed one in.
void main() {
  group('buildPeerConnectionConfig', () {
    test('carries the ICE servers it is given', () {
      final cfg = FlutterWebRtcPeerConnectionPort.buildPeerConnectionConfig(
        iceServers: const [
          {
            'urls': ['turns:relay.example:443'],
            'username': 'u',
            'credential': 'c',
          },
        ],
      );
      expect(cfg['iceServers'], hasLength(1));
      expect((cfg['iceServers'] as List).first, containsPair('username', 'u'));
    });

    test(
      'defaults to policy all — relaying everything is never the default',
      () {
        final cfg = FlutterWebRtcPeerConnectionPort.buildPeerConnectionConfig();
        expect(cfg['iceTransportPolicy'], 'all');
        expect(cfg['iceServers'], isEmpty);
      },
    );

    test('passes relay policy through when asked', () {
      final cfg = FlutterWebRtcPeerConnectionPort.buildPeerConnectionConfig(
        iceTransportPolicy: 'relay',
      );
      expect(cfg['iceTransportPolicy'], 'relay');
    });

    test('keeps unified-plan semantics', () {
      final cfg = FlutterWebRtcPeerConnectionPort.buildPeerConnectionConfig();
      expect(cfg['sdpSemantics'], 'unified-plan');
    });

    // The session-binding design (docs/DESIGN_session_binding.md) argues that
    // a replayed attestation is at worst denial of service, because the DTLS
    // certificate's private key lives only inside the peer's live connection.
    // That holds only while certificates stay ephemeral. Adding a persistent
    // `certificates` entry — to save a handshake, say — would make replayed
    // attestations usable and quietly cost the design a property nobody would
    // re-derive. So the invariant is measured here rather than trusted.
    test('never pins a persistent DTLS certificate', () {
      for (final cfg in [
        FlutterWebRtcPeerConnectionPort.buildPeerConnectionConfig(),
        FlutterWebRtcPeerConnectionPort.buildPeerConnectionConfig(
          iceTransportPolicy: 'relay',
        ),
      ]) {
        expect(
          cfg.containsKey('certificates'),
          isFalse,
          reason: 'a reused certificate makes a replayed session attestation '
              'usable; see docs/DESIGN_session_binding.md',
        );
      }
    });
  });
}
