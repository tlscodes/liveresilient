import 'dart:convert';

import 'package:signaling/signaling.dart';
import 'package:test/test.dart';

import 'support/fakes.dart';

void main() {
  group('SignalEnvelope JSON / bytes roundtrip', () {
    test('toJson/fromJson roundtrips every field', () {
      final envelope = testEnvelope(
        messageId: 'msg-1',
        sequence: 7,
        callId: 'call-42',
        senderKeyId: 'key-42',
        type: SignalType.iceCandidate,
        createdAtMs: 1700000000000,
        payload: const {
          'candidate': 'a=candidate:1',
          'nested': {'k': 1},
        },
      );

      final decoded = SignalEnvelope.fromJson(envelope.toJson());

      expect(decoded.version, envelope.version);
      expect(decoded.messageId, 'msg-1');
      expect(decoded.sequence, 7);
      expect(decoded.callId, 'call-42');
      expect(decoded.senderKeyId, 'key-42');
      expect(decoded.type, SignalType.iceCandidate);
      expect(decoded.createdAtMs, 1700000000000);
      expect(decoded.payload, envelope.payload);
    });

    test('toBytes/fromBytes roundtrips through UTF-8 JSON', () {
      final envelope = testEnvelope(type: SignalType.callControl);
      final bytes = envelope.toBytes();
      final decoded = SignalEnvelope.fromBytes(bytes);

      expect(decoded.messageId, envelope.messageId);
      expect(decoded.type, SignalType.callControl);
      expect(utf8.decode(bytes), contains('"type":"callControl"'));
    });

    for (final type in SignalType.values) {
      test('roundtrips every SignalType value: ${type.name}', () {
        final envelope = testEnvelope(type: type);
        final decoded = SignalEnvelope.fromBytes(envelope.toBytes());
        expect(decoded.type, type);
      });
    }

    test('payload is unmodifiable', () {
      final envelope = testEnvelope(payload: const {'a': 1});
      expect(() => envelope.payload['a'] = 2, throwsUnsupportedError);
    });
  });

  group('SignalEnvelope.fromJson malformed input', () {
    test('missing version throws FormatException', () {
      final json = testEnvelope().toJson()..remove('v');
      expect(() => SignalEnvelope.fromJson(json), throwsFormatException);
    });

    test('mistyped version (string instead of int) throws', () {
      final json = testEnvelope().toJson();
      json['v'] = '1';
      expect(() => SignalEnvelope.fromJson(json), throwsFormatException);
    });

    for (final field in [
      'id',
      'seq',
      'callId',
      'senderKeyId',
      'type',
      'createdAtMs',
    ]) {
      test('mistyped field "$field" throws FormatException', () {
        final json = testEnvelope().toJson();
        json[field] = <String, Object?>{'wrong': 'type'};
        expect(() => SignalEnvelope.fromJson(json), throwsFormatException);
      });
    }

    test('unknown type throws FormatException', () {
      final json = testEnvelope().toJson();
      json['type'] = 'not-a-real-type';
      expect(() => SignalEnvelope.fromJson(json), throwsFormatException);
    });

    test('non-map payload throws FormatException', () {
      final json = testEnvelope().toJson();
      json['payload'] = 'not-a-map';
      expect(() => SignalEnvelope.fromJson(json), throwsFormatException);
    });

    test('frame exceeding 64KiB throws FormatException on toBytes()', () {
      expect(
        () => testEnvelope(payload: {'blob': 'x' * (64 * 1024)}).toBytes(),
        throwsFormatException,
      );
    });

    test('frame exceeding 64KiB throws FormatException on fromBytes()', () {
      // A structurally valid but oversized frame, built by hand: the
      // constructor path already rejects an oversized envelope at
      // toBytes() (see above), so the incoming-frame limit is exercised
      // directly against raw bytes here.
      final oversized = utf8.encode(
        jsonEncode({
          'v': signalProtocolVersion,
          'id': 'oversized',
          'seq': 1,
          'callId': 'call-1',
          'senderKeyId': 'key-1',
          'type': 'offer',
          'createdAtMs': 1,
          'payload': {'blob': 'x' * (64 * 1024)},
        }),
      );
      expect(() => SignalEnvelope.fromBytes(oversized), throwsFormatException);
    });

    test('invalid JSON syntax throws FormatException', () {
      expect(
        () => SignalEnvelope.fromBytes(utf8.encode('not json at all')),
        throwsFormatException,
      );
    });

    test('invalid UTF-8 byte sequence throws FormatException', () {
      expect(
        () => SignalEnvelope.fromBytes([0xC3, 0x28, 0xA0]),
        throwsFormatException,
      );
    });

    test('non-object JSON root throws FormatException', () {
      expect(
        () => SignalEnvelope.fromBytes(utf8.encode(jsonEncode([1, 2, 3]))),
        throwsFormatException,
      );
    });
  });

  group('SignalEnvelope.buildAck', () {
    test('carries ackedMessageId, swaps sender/type, keeps callId', () {
      final original = testEnvelope(
        messageId: 'orig-1',
        senderKeyId: 'sender-a',
        callId: 'call-shared',
      );
      final ack = original.buildAck(
        ackSenderKeyId: 'sender-b',
        sequence: 9,
        nowMs: 1234567,
      );

      expect(ack.type, SignalType.ack);
      expect(ack.payload['ackedMessageId'], 'orig-1');
      expect(ack.senderKeyId, 'sender-b');
      expect(ack.sequence, 9);
      expect(ack.createdAtMs, 1234567);
      expect(ack.callId, 'call-shared');
      expect(ack.messageId, isNot('orig-1'));
    });
  });

  group('SignalEnvelope constructor validation bounds', () {
    test('empty messageId throws FormatException', () {
      expect(() => testEnvelope(messageId: ''), throwsFormatException);
    });

    test('messageId longer than 64 characters throws FormatException', () {
      expect(() => testEnvelope(messageId: 'a' * 65), throwsFormatException);
    });

    test('messageId at exactly 64 characters is accepted', () {
      expect(() => testEnvelope(messageId: 'a' * 64), returnsNormally);
    });

    test('sequence < 1 throws FormatException', () {
      expect(() => testEnvelope(sequence: 0), throwsFormatException);
      expect(() => testEnvelope(sequence: -5), throwsFormatException);
    });

    test('createdAtMs <= 0 throws FormatException', () {
      expect(() => testEnvelope(createdAtMs: 0), throwsFormatException);
      expect(() => testEnvelope(createdAtMs: -1), throwsFormatException);
    });

    test('empty or over-long callId throws FormatException', () {
      expect(() => testEnvelope(callId: ''), throwsFormatException);
      expect(() => testEnvelope(callId: 'c' * 129), throwsFormatException);
    });

    test('empty or over-long senderKeyId throws FormatException', () {
      expect(() => testEnvelope(senderKeyId: ''), throwsFormatException);
      expect(() => testEnvelope(senderKeyId: 'k' * 129), throwsFormatException);
    });

    test('unsupported protocol version throws FormatException', () {
      expect(
        () => SignalEnvelope(
          version: signalProtocolVersion + 1,
          messageId: 'id-1',
          sequence: 1,
          callId: 'call-1',
          senderKeyId: 'key-1',
          type: SignalType.offer,
          createdAtMs: 1,
          payload: const {},
        ),
        throwsFormatException,
      );
    });
  });

  group('generateSignalMessageId', () {
    test('produces non-empty, URL-safe, unique ids', () {
      final ids = {for (var i = 0; i < 200; i++) generateSignalMessageId()};
      expect(ids.length, 200); // no collisions across 200 draws
      for (final id in ids) {
        expect(id, isNotEmpty);
        expect(id, isNot(contains('=')));
        expect(id, isNot(contains('+')));
        expect(id, isNot(contains('/')));
      }
    });
  });

  group('SignalEnvelope.toString', () {
    test('includes type, id, sequence, call', () {
      final envelope = testEnvelope(
        messageId: 'msg-x',
        sequence: 3,
        callId: 'call-y',
        type: SignalType.answer,
      );
      final s = envelope.toString();
      expect(s, contains('answer'));
      expect(s, contains('msg-x'));
      expect(s, contains('3'));
      expect(s, contains('call-y'));
    });
  });
}
