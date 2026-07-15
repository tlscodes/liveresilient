import 'package:call_core/call_core.dart';
import 'package:call_signaling_adapter/call_signaling_adapter.dart';
import 'package:signaling/signaling.dart';
import 'package:test/test.dart';

void main() {
  group('encodeCommand', () {
    test('offer description encodes to SignalType.offer', () {
      final (type, payload) = encodeCommand(
        SendDescriptionCommand(
          SessionDescription(type: SessionDescriptionType.offer, sdp: 'v=0'),
        ),
      );
      expect(type, SignalType.offer);
      expect(payload, {'type': 'offer', 'sdp': 'v=0'});
    });

    test('answer description encodes to SignalType.answer', () {
      final (type, payload) = encodeCommand(
        SendDescriptionCommand(
          SessionDescription(type: SessionDescriptionType.answer, sdp: 'v=0'),
        ),
      );
      expect(type, SignalType.answer);
      expect(payload, {'type': 'answer', 'sdp': 'v=0'});
    });

    test('ice candidate encodes candidate/sdpMid/sdpMLineIndex', () {
      final (type, payload) = encodeCommand(
        SendIceCandidateCommand(
          IceCandidate(
            candidate: 'candidate:1 1 UDP 1 1.1.1.1 1 typ host',
            sdpMid: '0',
            sdpMLineIndex: 0,
          ),
        ),
      );
      expect(type, SignalType.iceCandidate);
      expect(payload, {
        'candidate': 'candidate:1 1 UDP 1 1.1.1.1 1 typ host',
        'sdpMid': '0',
        'sdpMLineIndex': 0,
      });
    });

    test('end-of-candidates (null candidate) encodes nulls', () {
      final (type, payload) = encodeCommand(
        SendIceCandidateCommand(IceCandidate(candidate: null)),
      );
      expect(type, SignalType.iceCandidate);
      expect(payload, {
        'candidate': null,
        'sdpMid': null,
        'sdpMLineIndex': null,
      });
    });

    test('hangup with reason encodes action + reason', () {
      final (type, payload) = encodeCommand(SendHangupCommand('user ended'));
      expect(type, SignalType.callControl);
      expect(payload, {'action': 'hangup', 'reason': 'user ended'});
    });

    test('hangup without reason omits the reason key', () {
      final (type, payload) = encodeCommand(SendHangupCommand());
      expect(type, SignalType.callControl);
      expect(payload, {'action': 'hangup'});
      expect(payload.containsKey('reason'), isFalse);
    });

    test('restart request encodes action only', () {
      final (type, payload) = encodeCommand(const SendRestartRequestCommand());
      expect(type, SignalType.callControl);
      expect(payload, {'action': 'restartRequest'});
    });
  });

  group('decodeInbound: offer/answer', () {
    test('valid offer decodes to RemoteDescriptionEvent', () {
      final event = decodeInbound(SignalType.offer, {
        'type': 'offer',
        'sdp': 'v=0',
      });
      expect(event, isA<RemoteDescriptionEvent>());
      final description = (event as RemoteDescriptionEvent).description;
      expect(description.type, SessionDescriptionType.offer);
      expect(description.sdp, 'v=0');
    });

    test('valid answer decodes to RemoteDescriptionEvent', () {
      final event = decodeInbound(SignalType.answer, {
        'type': 'answer',
        'sdp': 'v=0',
      });
      expect(event, isA<RemoteDescriptionEvent>());
      expect(
        (event as RemoteDescriptionEvent).description.type,
        SessionDescriptionType.answer,
      );
    });

    test('missing sdp returns null', () {
      expect(decodeInbound(SignalType.offer, const {}), isNull);
    });

    test('non-string sdp returns null', () {
      expect(decodeInbound(SignalType.offer, {'sdp': 42}), isNull);
    });

    test('sdp failing SessionDescription validation returns null', () {
      // Must start with 'v=0' per SessionDescription's own validation.
      expect(decodeInbound(SignalType.offer, {'sdp': 'not-sdp'}), isNull);
    });
  });

  group('decodeInbound: iceCandidate', () {
    test('valid candidate decodes to RemoteIceCandidateEvent', () {
      final event = decodeInbound(SignalType.iceCandidate, {
        'candidate': 'candidate:1 1 UDP 1 1.1.1.1 1 typ host',
        'sdpMid': '0',
        'sdpMLineIndex': 0,
      });
      expect(event, isA<RemoteIceCandidateEvent>());
      final candidate = (event as RemoteIceCandidateEvent).candidate;
      expect(candidate.candidate, 'candidate:1 1 UDP 1 1.1.1.1 1 typ host');
      expect(candidate.sdpMid, '0');
      expect(candidate.sdpMLineIndex, 0);
    });

    test('null candidate (end-of-candidates) decodes with null fields', () {
      final event = decodeInbound(SignalType.iceCandidate, const {
        'candidate': null,
        'sdpMid': null,
        'sdpMLineIndex': null,
      });
      expect(event, isA<RemoteIceCandidateEvent>());
      expect((event as RemoteIceCandidateEvent).candidate.candidate, isNull);
    });

    test('missing keys treated as null (end-of-candidates)', () {
      final event = decodeInbound(SignalType.iceCandidate, const {});
      expect(event, isA<RemoteIceCandidateEvent>());
    });

    test('non-string candidate returns null', () {
      expect(decodeInbound(SignalType.iceCandidate, {'candidate': 7}), isNull);
    });

    test('non-string sdpMid returns null', () {
      expect(
        decodeInbound(SignalType.iceCandidate, {
          'candidate': 'candidate:1 1 UDP 1 1.1.1.1 1 typ host',
          'sdpMid': 7,
        }),
        isNull,
      );
    });

    test('non-int sdpMLineIndex returns null', () {
      expect(
        decodeInbound(SignalType.iceCandidate, {
          'candidate': 'candidate:1 1 UDP 1 1.1.1.1 1 typ host',
          'sdpMLineIndex': '0',
        }),
        isNull,
      );
    });

    test('candidate present without sdpMid/sdpMLineIndex fails validation', () {
      expect(
        decodeInbound(SignalType.iceCandidate, {
          'candidate': 'candidate:1 1 UDP 1 1.1.1.1 1 typ host',
        }),
        isNull,
      );
    });
  });

  group('decodeInbound: callControl', () {
    test('hangup with reason decodes to RemoteHangupEvent', () {
      final event = decodeInbound(SignalType.callControl, {
        'action': 'hangup',
        'reason': 'bye',
      });
      expect(event, isA<RemoteHangupEvent>());
      expect((event as RemoteHangupEvent).reason, 'bye');
    });

    test('hangup without reason decodes to RemoteHangupEvent(null)', () {
      final event = decodeInbound(SignalType.callControl, {'action': 'hangup'});
      expect(event, isA<RemoteHangupEvent>());
      expect((event as RemoteHangupEvent).reason, isNull);
    });

    test('hangup with non-string reason returns null', () {
      expect(
        decodeInbound(SignalType.callControl, {
          'action': 'hangup',
          'reason': 7,
        }),
        isNull,
      );
    });

    test('hangup with reason failing validation returns null', () {
      expect(
        decodeInbound(SignalType.callControl, {
          'action': 'hangup',
          'reason': 'x' * 300,
        }),
        isNull,
      );
    });

    test('restartRequest decodes to RestartRequestedEvent', () {
      final event = decodeInbound(SignalType.callControl, const {
        'action': 'restartRequest',
      });
      expect(event, isA<RestartRequestedEvent>());
    });

    test('unknown action is ignored (forward-compat), returns null', () {
      expect(
        decodeInbound(SignalType.callControl, {'action': 'somethingNew'}),
        isNull,
      );
    });

    test('missing action returns null', () {
      expect(decodeInbound(SignalType.callControl, const {}), isNull);
    });

    test('non-string action returns null', () {
      expect(decodeInbound(SignalType.callControl, {'action': 1}), isNull);
    });
  });

  group('decodeInbound: internal-only types', () {
    test('ack returns null', () {
      expect(decodeInbound(SignalType.ack, const {}), isNull);
    });

    test('heartbeat returns null', () {
      expect(decodeInbound(SignalType.heartbeat, const {}), isNull);
    });
  });
}
