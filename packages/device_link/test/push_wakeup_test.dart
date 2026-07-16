import 'dart:convert';

import 'package:device_link/device_link.dart';
import 'package:test/test.dart';

void main() {
  const nowMs = 1000000;

  PushWakeupPayload payload({
    String callId = 'call-abc-123',
    int issuedAtMs = nowMs,
    int? expiresAtMs,
  }) {
    return PushWakeupPayload(
      callId: callId,
      issuedAtMs: issuedAtMs,
      expiresAtMs: expiresAtMs ?? issuedAtMs + 60 * 1000,
    );
  }

  group('PushWakeupPayload', () {
    test('round-trips through encode/decode', () {
      final original = payload();
      final decoded = PushWakeupPayload.decode(original.encode());

      expect(decoded.callId, original.callId);
      expect(decoded.issuedAtMs, original.issuedAtMs);
      expect(decoded.expiresAtMs, original.expiresAtMs);
      expect(decoded.schemaVersion, PushWakeupPayload.currentSchemaVersion);
    });

    test('rejects callId with characters outside the opaque alphabet', () {
      expect(() => payload(callId: 'call{"sdp":1}'), throwsFormatException);
      expect(() => payload(callId: 'call id spaced'), throwsFormatException);
    });

    test('rejects callId shorter than 8 or longer than 64 characters', () {
      expect(() => payload(callId: 'short'), throwsFormatException);
      expect(() => payload(callId: 'a' * 65), throwsFormatException);
      expect(payload(callId: 'a' * 8).callId.length, 8);
      expect(payload(callId: 'a' * 64).callId.length, 64);
    });

    test('rejects a lifetime beyond the 5-minute TTL bound', () {
      expect(
        () => payload(expiresAtMs: nowMs + PushWakeupPayload.maxTtlMs + 1),
        throwsFormatException,
      );
      expect(
        payload(expiresAtMs: nowMs + PushWakeupPayload.maxTtlMs),
        isA<PushWakeupPayload>(),
      );
    });

    test('rejects expiry at or before issuance and negative issuance', () {
      expect(() => payload(expiresAtMs: nowMs), throwsFormatException);
      expect(() => payload(expiresAtMs: nowMs - 1), throwsFormatException);
      expect(
        () => payload(issuedAtMs: -1, expiresAtMs: 1000),
        throwsFormatException,
      );
    });

    test('rejects unsupported schema versions', () {
      expect(
        () => PushWakeupPayload(
          callId: 'call-abc-123',
          issuedAtMs: nowMs,
          expiresAtMs: nowMs + 1000,
          schemaVersion: 2,
        ),
        throwsFormatException,
      );
    });

    test('rejects any unknown key — no room for SDP/keys/contacts', () {
      final json = payload().toJson().cast<String, Object?>();
      json['sdp'] = 'v=0';

      expect(() => PushWakeupPayload.fromJson(json), throwsFormatException);
    });

    test('rejects missing fields and wrong field types', () {
      final valid = payload().toJson().cast<String, Object?>();

      final missing = Map<String, Object?>.from(valid)..remove('callId');
      expect(() => PushWakeupPayload.fromJson(missing), throwsFormatException);

      final wrongType = Map<String, Object?>.from(valid)
        ..['issuedAtMs'] = 'yesterday';
      expect(
        () => PushWakeupPayload.fromJson(wrongType),
        throwsFormatException,
      );
    });

    test('rejects raw payloads over the encoded size cap', () {
      final oversized = '{"callId":"call-abc-123","padding":"${'x' * 600}"}';
      expect(
        utf8.encode(oversized).length,
        greaterThan(PushWakeupPayload.maxEncodedBytes),
      );
      expect(() => PushWakeupPayload.decode(oversized), throwsFormatException);
    });

    test('rejects non-JSON and non-object payloads', () {
      expect(() => PushWakeupPayload.decode('not json'), throwsFormatException);
      expect(() => PushWakeupPayload.decode('[1,2,3]'), throwsFormatException);
    });
  });

  group('PushWakeupProcessor', () {
    test('duplicate push never announces a second incoming call', () {
      final announced = <String>[];
      final processor = PushWakeupProcessor(
        onIncomingCallAnnounced: announced.add,
      );
      final wakeup = payload();

      expect(processor.handle(wakeup, nowMs: nowMs), PushWakeupResult.accepted);
      expect(
        processor.handle(wakeup, nowMs: nowMs + 5000),
        PushWakeupResult.duplicate,
      );
      expect(announced, ['call-abc-123']);
    });

    test('expired push is rejected and announces nothing', () {
      final announced = <String>[];
      final processor = PushWakeupProcessor(
        onIncomingCallAnnounced: announced.add,
      );
      final wakeup = payload(expiresAtMs: nowMs + 1000);

      expect(
        processor.handle(wakeup, nowMs: nowMs + 1000),
        PushWakeupResult.expired,
      );
      expect(announced, isEmpty);
    });

    test('a replay arriving after expiry stays rejected, not re-accepted', () {
      final processor = PushWakeupProcessor();
      final wakeup = payload(expiresAtMs: nowMs + 1000);

      expect(processor.handle(wakeup, nowMs: nowMs), PushWakeupResult.accepted);
      expect(
        processor.handle(wakeup, nowMs: nowMs + 2000),
        PushWakeupResult.expired,
      );
    });

    test('payload issued too far in the future is malformed', () {
      final processor = PushWakeupProcessor();
      final wakeup = payload(
        issuedAtMs: nowMs + PushWakeupProcessor.maxClockSkewMs + 1,
        expiresAtMs: nowMs + PushWakeupProcessor.maxClockSkewMs + 60000,
      );

      expect(
        processor.handle(wakeup, nowMs: nowMs),
        PushWakeupResult.malformed,
      );
    });

    test('handleRaw accepts a valid payload and flags malformed input', () {
      final processor = PushWakeupProcessor();

      expect(
        processor.handleRaw(payload().encode(), nowMs: nowMs),
        PushWakeupResult.accepted,
      );
      expect(
        processor.handleRaw('{"callId":', nowMs: nowMs),
        PushWakeupResult.malformed,
      );
      expect(
        processor.handleRaw(
          '{"schemaVersion":1,"callId":"call-abc-999","issuedAtMs":$nowMs,'
          '"expiresAtMs":${nowMs + 1000},"contact":"+491234"}',
          nowMs: nowMs,
        ),
        PushWakeupResult.malformed,
      );
    });

    test('seen-cache is bounded: oldest call IDs are evicted', () {
      final processor = PushWakeupProcessor(maximumTrackedCallIds: 3);

      for (var i = 0; i < 4; i++) {
        expect(
          processor.handle(payload(callId: 'call-id-$i'), nowMs: nowMs),
          PushWakeupResult.accepted,
        );
      }

      // call-id-0 was evicted by the bound, so its replay is no longer
      // recognized as a duplicate; the newest entries still are.
      expect(
        processor.handle(payload(callId: 'call-id-0'), nowMs: nowMs),
        PushWakeupResult.accepted,
      );
      expect(
        processor.handle(payload(callId: 'call-id-3'), nowMs: nowMs),
        PushWakeupResult.duplicate,
      );
    });
  });
}
