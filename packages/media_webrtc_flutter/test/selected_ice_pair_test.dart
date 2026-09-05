/// Unit tests for [FlutterWebRtcPeerConnectionPort.selectedIcePairFromStats]:
/// which candidate pair counts as selected, and how a TURN-over-TCP relay
/// candidate is described.
///
/// The field that matters on a filtered access network is `relayProtocol`:
/// a relay candidate's own `protocol` is the RELAYED leg (udp for classic
/// TURN) while `relayProtocol` is the leg this endpoint puts on the wire.
/// A row that read `protocol` alone would report "udp" for a call that in
/// fact emitted only TCP.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:media_webrtc_flutter/media_webrtc_flutter.dart';

rtc.StatsReport _report(String id, String type, Map<dynamic, dynamic> values) {
  return rtc.StatsReport(id, type, 0, values);
}

void main() {
  group('selectedIcePairFromStats', () {
    test('returns null when no pair is selected or flagged', () {
      expect(
        FlutterWebRtcPeerConnectionPort.selectedIcePairFromStats([
          _report('cp1', 'candidate-pair', {'state': 'in-progress'}),
          _report('lc1', 'local-candidate', {'candidateType': 'host'}),
        ]),
        isNull,
      );
    });

    test('resolves the pair named by transport.selectedCandidatePairId and '
        'reports relayProtocol as the wire protocol', () {
      final pair = FlutterWebRtcPeerConnectionPort.selectedIcePairFromStats([
        _report('t1', 'transport', {'selectedCandidatePairId': 'cp2'}),
        _report('cp1', 'candidate-pair', {
          'localCandidateId': 'lc1',
          'remoteCandidateId': 'rc1',
          'state': 'failed',
        }),
        _report('cp2', 'candidate-pair', {
          'localCandidateId': 'lc2',
          'remoteCandidateId': 'rc2',
          'state': 'succeeded',
        }),
        _report('lc1', 'local-candidate', {
          'candidateType': 'host',
          'protocol': 'udp',
        }),
        _report('lc2', 'local-candidate', {
          'candidateType': 'relay',
          'protocol': 'udp',
          'relayProtocol': 'tcp',
        }),
        _report('rc2', 'remote-candidate', {
          'candidateType': 'relay',
          'protocol': 'udp',
        }),
      ])!;
      expect(pair.localCandidateType, 'relay');
      expect(pair.localProtocol, 'udp');
      expect(pair.localRelayProtocol, 'tcp');
      expect(pair.remoteCandidateType, 'relay');
      expect(pair.state, 'succeeded');
      expect(pair.wireProtocol, 'tcp');
    });

    test('falls back to the nominated+succeeded pair when no transport '
        'report names one', () {
      final pair = FlutterWebRtcPeerConnectionPort.selectedIcePairFromStats([
        _report('cp1', 'candidate-pair', {
          'localCandidateId': 'lc1',
          'nominated': true,
          'state': 'succeeded',
        }),
        _report('lc1', 'local-candidate', {
          'candidateType': 'host',
          'protocol': 'udp',
        }),
      ])!;
      expect(pair.localCandidateType, 'host');
      expect(pair.wireProtocol, 'udp', reason: 'no relay leg to prefer');
    });

    test('a pair whose candidate reports are absent still resolves, with '
        'null fields instead of a thrown error', () {
      final pair = FlutterWebRtcPeerConnectionPort.selectedIcePairFromStats([
        _report('cp1', 'candidate-pair', {'selected': true, 'state': 'ok'}),
      ])!;
      expect(pair.localCandidateType, isNull);
      expect(pair.wireProtocol, isNull);
      expect(pair.state, 'ok');
      expect(pair.toJson()['local_relay_protocol'], isNull);
    });
  });
}
