/// Pins the arm-time gate of the phone peer's blackout job: a plan that can
/// never deliver is rejected before a bundle is queued, with the error text
/// the `failed` report carries.
///
/// Scenario pinned (refuter finding, journey_peer_app.dart:540): the runner
/// started with JOURNEY_BLACKOUT_STREAM_PORT=0, so job.json carried
/// "stream":{"port":0,...}. BlackoutPlan.parse yields a full item list (a
/// stream map exists), portOf() yields null, and without the gate every probe
/// hit the "plan carries no stream port" early return in _streamFlush for the
/// whole lifetime_s (default 21600 s) before the phone reported failed.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reference_app/src/voice_letter_recorder.dart';

import '../integration_test/blackout_forwarder.dart';
import '../integration_test/journey_peer_app.dart';
import '../integration_test/whitelist_door.dart';

void main() {
  const plan = [
    {'kind': 'text', 'bytes': 200, 'n': 2},
    {'kind': 'photo', 'bytes': 45000, 'n': 1},
  ];

  Map<String, Object?> stream(Object? port) => {
    'port': port,
    'piece_bytes': 8192,
    'ack_bytes': 8192,
    'ack_interval_s': 2,
    'inflight_bytes': 32768,
    'stall_s': 15,
  };

  test('a v3 plan with a usable stream port is accepted', () {
    final v3 = BlackoutPlan.parse({
      'v': 3,
      'plan': plan,
      'stream': stream(8766),
    })!;
    expect(v3.items.length, 3);
    expect(blackoutPlanRejection(v3), isNull);
  });

  test('a v3 plan whose stream map has port 0 is rejected at arm time', () {
    // The exact shape JOURNEY_BLACKOUT_STREAM_PORT=0 produces: items parse
    // (a stream map exists) but the port is unusable.
    final v3 = BlackoutPlan.parse({'v': 3, 'plan': plan, 'stream': stream(0)})!;
    expect(v3.items.length, 3, reason: 'parse keeps the items');
    expect(
      blackoutPlanRejection(v3),
      'blackout v3 plan carries no stream port',
    );
  });

  test('absent, out-of-range and non-int ports are rejected the same way', () {
    for (final port in <Object?>[null, -1, 65536, '8766', 8766.0]) {
      final v3 = BlackoutPlan.parse({
        'v': 3,
        'plan': plan,
        'stream': stream(port),
      })!;
      expect(v3.items.length, 3, reason: 'port=$port');
      expect(
        blackoutPlanRejection(v3),
        'blackout v3 plan carries no stream port',
        reason: 'port=$port',
      );
    }
    final noPortKey = BlackoutPlan.parse({
      'v': 3,
      'plan': plan,
      'stream': <String, Object?>{'piece_bytes': 8192},
    })!;
    expect(
      blackoutPlanRejection(noPortKey),
      'blackout v3 plan carries no stream port',
    );
  });

  test('a v3 plan without a stream map is rejected as empty', () {
    final v3 = BlackoutPlan.parse({'v': 3, 'plan': plan})!;
    expect(v3.items, isEmpty);
    expect(blackoutPlanRejection(v3), 'blackout v3 plan is empty');
  });

  test('v2 plans never need a stream port; an empty v2 plan is rejected', () {
    final v2 = BlackoutPlan.parse({'v': 2, 'plan': plan})!;
    expect(blackoutPlanRejection(v2), isNull);
    final v2WithPortZero = BlackoutPlan.parse({
      'v': 2,
      'plan': plan,
      'stream': stream(0),
    })!;
    expect(blackoutPlanRejection(v2WithPortZero), isNull);
    final v2Empty = BlackoutPlan.parse({'v': 2, 'plan': <Object?>[]})!;
    expect(blackoutPlanRejection(v2Empty), 'blackout v2 plan is empty');
  });

  // --- the whitelist profile's job wiring (refuter finding, 2026-09-05) ---
  //
  // The finding said the phone-side wiring was still an unapplied patch, so
  // the `"whitelist":{...}` map tools/t2/journey_run.sh:143-152 posts would be
  // discarded and the profile could not produce a row at all. The wiring is in
  // the file at HEAD (journey_peer_app.dart:85 the field, :106 and :112 the
  // parse, :315-327 the arm-time config gate, :329-341 the relay-only ICE,
  // :342-350 the door loop and the two controls). These tests pin it, so a
  // peer that loses the field again fails here rather than on the rig, after a
  // filter load, a coturn start and a ~20 min build.

  // The string tools/t2/journey_run.sh:143-152 prints for this profile with
  // its documented defaults: RELAY_PORT 4443, WHITELIST_DOOR_INTERVAL_S 1,
  // blocked host 192.168.2.9, rst and quic port 443, quic timeout 3000 ms.
  const runnerJobJson =
      '{"run":"r1","key":"k1","hold_s":700,"profile":"whitelist",'
      '"whitelist":{"url":"https://192.168.2.1:4443/","interval_s":1,'
      '"blocked_host":"192.168.2.9","rst_port":443,"quic_port":443,'
      '"quic_timeout_ms":3000,"relay_only":true}}';

  test('the whitelist job the runner posts reaches the peer intact', () {
    final job = JourneyJob.tryParse(runnerJobJson)!;
    expect(job.run, 'r1');
    expect(job.key, 'k1');
    expect(job.holdS, 700);
    expect(job.blackout, isNull, reason: 'the queue path stays unbuilt');
    expect(job.whitelist, isNotNull, reason: 'the map must not be discarded');
    final config = WhitelistDoorConfig.parse(job.whitelist!);
    expect(config.url, 'https://192.168.2.1:4443/');
    expect(config.interval, const Duration(seconds: 1));
    expect(config.blockedHost, '192.168.2.9');
    expect(config.rstPort, 443);
    expect(config.quicPort, 443);
    expect(config.quicTimeout, const Duration(milliseconds: 3000));
    expect(config.relayOnly, isTrue, reason: 'ICE is forced relay-only');
  });

  test('a job without a whitelist map leaves the door absent', () {
    final job = JourneyJob.tryParse(
      '{"run":"r1","key":"k1","hold_s":400,"profile":"normal"}',
    )!;
    expect(job.whitelist, isNull);
    expect(job.blackout, isNull);
  });

  test('a whitelist value that is not a map is ignored, never a crash', () {
    final job = JourneyJob.tryParse(
      '{"run":"r1","key":"k1","hold_s":400,"whitelist":"yes"}',
    )!;
    expect(job.whitelist, isNull);
  });

  test('a whitelist map without url is rejected at arm time', () {
    expect(
      () => WhitelistDoorConfig.parse(const <String, Object?>{'interval_s': 1}),
      throwsA(isA<FormatException>()),
    );
  });

  // --- the dnsvalve profile's job wiring (2026-09-13) ---
  //
  // The peer's call path builds an E2eCallStack, which constructs no
  // ConnectionFabric, so this build's DNS_VALVE_* defines carry no lane on
  // their own: the `dns_valve` map is what makes the peer register one. A
  // peer that discards the map produces no `lane` event at all, and the Mac
  // then reports a branch that never ran — after a rig hour. These pin the
  // parse so that failure lands here instead.

  const dnsValveJobJson =
      '{"run":"r2","key":"k2","hold_s":700,"profile":"dnsvalve",'
      '"dns_valve":{"zone":"valve.example","resolvers":["192.168.2.1:5300"],'
      '"chat_bytes":64,"select_budget_s":90,"carry_budget_s":150,'
      '"relay_only":true}}';

  test('a job without dns_valve parses exactly as before', () {
    final job = JourneyJob.tryParse(
      '{"run":"r1","key":"k1","hold_s":400,"profile":"normal"}',
    )!;
    expect(job.run, 'r1');
    expect(job.key, 'k1');
    expect(job.holdS, 400);
    expect(job.dnsValve, isNull, reason: 'no fabric branch is armed');
    expect(job.whitelist, isNull);
    expect(job.blackout, isNull);
  });

  test('the dnsvalve job the runner posts reaches the peer intact', () {
    final job = JourneyJob.tryParse(dnsValveJobJson)!;
    expect(job.run, 'r2');
    expect(job.key, 'k2');
    expect(job.holdS, 700);
    expect(job.blackout, isNull, reason: 'the call is placed, not replaced');
    expect(job.whitelist, isNull);
    expect(job.dnsValve, isNotNull, reason: 'the map must not be discarded');

    final config = DnsValveConfig.parse(job.dnsValve!);
    expect(config.zone, 'valve.example');
    expect(config.resolvers.length, 1);
    expect(config.resolvers.single.host, '192.168.2.1');
    expect(config.resolvers.single.port, 5300);
    expect(config.chatBytes, 64);
    expect(config.selectBudget, const Duration(seconds: 90));
    expect(config.carryBudget, const Duration(seconds: 150));
    expect(config.relayOnly, isTrue, reason: 'ICE is forced relay-only');
    expect(config.totalBudget, const Duration(seconds: 240));
    expect(config.toJson()['resolvers'], <String>['192.168.2.1:5300']);
  });

  test('a dns_valve value that is not a map is ignored, never a crash', () {
    final job = JourneyJob.tryParse(
      '{"run":"r1","key":"k1","hold_s":400,"dns_valve":"yes"}',
    )!;
    expect(job.dnsValve, isNull);
  });

  test('dns_valve defaults fill in, and relay_only stays off', () {
    final config = DnsValveConfig.parse(const <String, Object?>{
      'zone': 'valve.example',
    });
    expect(config.resolvers, isEmpty, reason: 'the device walks its own');
    expect(config.chatBytes, 64);
    expect(config.selectBudget, const Duration(seconds: 120));
    expect(config.carryBudget, const Duration(seconds: 120));
    expect(config.relayOnly, isFalse);
  });

  test('a dns_valve map that cannot produce a row is rejected at arm time', () {
    // No zone: the lane has nothing to query.
    expect(
      () => DnsValveConfig.parse(const <String, Object?>{'chat_bytes': 64}),
      throwsA(isA<FormatException>()),
    );
    // A message longer than the lane's own limit is refused as transient by
    // the valve, so the fabric would carry it on a WAN lane and the row
    // would read `carried_without_selection` for a config reason.
    expect(
      () => DnsValveConfig.parse(const <String, Object?>{
        'zone': 'valve.example',
        'chat_bytes': 5000,
      }),
      throwsA(isA<FormatException>()),
    );
    // A resolver that is not host:port is a runner bug, never dropped.
    expect(
      () => DnsValveConfig.parse(const <String, Object?>{
        'zone': 'valve.example',
        'resolvers': <String>['192.168.2.1'],
      }),
      throwsA(isA<FormatException>()),
    );
    for (final field in const ['chat_bytes', 'select_budget_s']) {
      expect(
        () => DnsValveConfig.parse(<String, Object?>{
          'zone': 'valve.example',
          field: 0,
        }),
        throwsA(isA<FormatException>()),
        reason: field,
      );
    }
  });

  group('the door line on the phone screen', () {
    test('the chunk count follows the wire split, never a copied constant', () {
      expect(txtChunkCount(0), 1);
      // The 200-byte runs made 7 attempts: 6 chunks and the probe.
      expect(txtChunkCount(200), 6);
      // The 1022-byte letter: 28 attempts, 27 chunks and the probe.
      expect(txtChunkCount(1022), 27);
      // The lane limit, as its own doc states: 106 round trips.
      expect(txtChunkCount(4096), 106);
    });

    test('closed, unproven, alive, slow and quiet are told apart', () {
      expect(
        doorLine(
          down: true,
          attempts: 3,
          landed: 0,
          total: 27,
          sinceReply: null,
        ),
        'door closed · lane down · chunks 0/27',
      );
      final unproven = doorLine(
        down: false,
        attempts: 2,
        landed: 0,
        total: 27,
        sinceReply: null,
      );
      expect(unproven, startsWith('door unproven'));
      expect(unproven, isNot(contains('alive')));
      expect(
        doorLine(
          down: false,
          attempts: 13,
          landed: 12,
          total: 27,
          sinceReply: const Duration(seconds: 3),
        ),
        'door open · alive · chunks 12/27 · reply 3s ago',
      );
      expect(
        doorLine(
          down: false,
          attempts: 30,
          landed: 12,
          total: 27,
          sinceReply: const Duration(seconds: 3),
        ),
        'door open · slow · alive · chunks 12/27 · reply 3s ago',
      );
      final quiet = doorLine(
        down: false,
        attempts: 30,
        landed: 12,
        total: 27,
        sinceReply: const Duration(seconds: 20),
      );
      expect(quiet, 'door open? · quiet 20s ago · chunks 12/27');
      expect(quiet, isNot(contains('alive')));
    });
  });

  group('the phone as the author', () {
    test('chat_source phone parses, round-trips and defaults to mac', () {
      final phone = DnsValveConfig.parse(<String, Object?>{
        'zone': 'valve.test',
        'resolvers': const ['192.168.2.1:5300'],
        'chat_source': 'phone',
      });
      expect(phone.chatSource, 'phone');
      expect(phone.chatText, isNull);
      expect(DnsValveConfig.parse(phone.toJson()).chatSource, 'phone');
      expect(
        DnsValveConfig.parse(<String, Object?>{
          'zone': 'valve.test',
        }).chatSource,
        'mac',
      );
    });

    test('two authors for one letter, or an unknown author, has no row', () {
      expect(
        () => DnsValveConfig.parse(<String, Object?>{
          'zone': 'valve.test',
          'chat_source': 'phone',
          'chat_bytes': 5,
          'chat_text_b64': base64.encode(utf8.encode('hello')),
        }),
        throwsFormatException,
      );
      expect(
        () => DnsValveConfig.parse(const <String, Object?>{
          'zone': 'valve.test',
          'chat_source': 'pigeon',
        }),
        throwsFormatException,
      );
    });

    test('the screen shows text as text and binary as a description', () {
      final text = Uint8List.fromList(utf8.encode('سلام از گوشی'));
      expect(describeLetter(text, 'a' * 64), 'سلام از گوشی');
      final binary = Uint8List.fromList(const [0xff, 0xd8, 0xff, 0xe0, 0x00]);
      expect(
        describeLetter(binary, 'abcdef0123456789ffff'),
        '<binary, 5 B, sha256 abcdef0123456789>',
      );
    });

    test(
      'the default phone letter names its origin and fits a few queries',
      () {
        final letter = phoneDefaultLetter('2026-09-14T00:00:00Z');
        expect(letter, startsWith('from the phone, run 2026-09-14T00:00:00Z'));
        expect(txtChunkCount(utf8.encode(letter).length), lessThanOrEqualTo(3));
      },
    );

    test('phone_wait_s defaults to zero and round-trips', () {
      final noWait = DnsValveConfig.parse(<String, Object?>{
        'zone': 'valve.test',
        'chat_source': 'phone',
      });
      expect(noWait.phoneWait, Duration.zero);
      final waited = DnsValveConfig.parse(<String, Object?>{
        'zone': 'valve.test',
        'chat_source': 'phone',
        'phone_wait_s': 45,
      });
      expect(waited.phoneWait, const Duration(seconds: 45));
      expect(
        DnsValveConfig.parse(waited.toJson()).phoneWait,
        const Duration(seconds: 45),
      );
    });

    test('phone_wait_s is capped at 120 s and never negative', () {
      expect(
        () => DnsValveConfig.parse(<String, Object?>{
          'zone': 'valve.test',
          'chat_source': 'phone',
          'phone_wait_s': 121,
        }),
        throwsFormatException,
      );
      expect(
        () => DnsValveConfig.parse(<String, Object?>{
          'zone': 'valve.test',
          'chat_source': 'phone',
          'phone_wait_s': -1,
        }),
        throwsFormatException,
      );
      // The cap itself is still legal.
      expect(
        DnsValveConfig.parse(<String, Object?>{
          'zone': 'valve.test',
          'chat_source': 'phone',
          'phone_wait_s': 120,
        }).phoneWait,
        const Duration(seconds: 120),
      );
    });

    test('submitLetter is a no-op with no window open, never throws', () {
      final peer = JourneyPeer();
      expect(peer.letterWanted.value, isFalse);
      expect(peer.voiceLetter.value, isNull);
      expect(peer.submitLetter, returnsNormally);
      expect(peer.letterWanted.value, isFalse);
    });
  });

  test('a job that names the letter carries those exact bytes', () {
    final letter = utf8.encode('call 18:30 Tehran, session UL7V62');
    final config = DnsValveConfig.parse(<String, Object?>{
      'zone': 'valve.test',
      'resolvers': const ['192.168.2.1:5300'],
      'chat_bytes': letter.length,
      'chat_text_b64': base64.encode(letter),
    });
    expect(config.chatText, letter);
    expect(config.toJson()['chat_text_b64'], base64.encode(letter));
    // Round trip: what the job said is what a re-parse carries.
    expect(DnsValveConfig.parse(config.toJson()).chatText, letter);
  });

  test('a letter whose length disagrees with chat_bytes has no row', () {
    expect(
      () => DnsValveConfig.parse(<String, Object?>{
        'zone': 'valve.test',
        'chat_bytes': 64,
        'chat_text_b64': base64.encode(utf8.encode('short')),
      }),
      throwsFormatException,
    );
    expect(
      () => DnsValveConfig.parse(const <String, Object?>{
        'zone': 'valve.test',
        'chat_bytes': 64,
        'chat_text_b64': 'not base64 at all !!',
      }),
      throwsFormatException,
    );
  });

  test(
    'the carried payload is exactly chat_bytes and derived from the run',
    () {
      final first = dnsValvePayload('r2', 64);
      expect(first.length, 64);
      expect(
        dnsValvePayload('r2', 64),
        first,
        reason: 'the Mac recomputes it from the run id it handed out',
      );
      expect(
        dnsValvePayload('r3', 64),
        isNot(first),
        reason: 'a stale run cannot satisfy another run sha256',
      );
      expect(dnsValvePayload('r2', 1).length, 1);
    },
  );

  group('the Record button on the phone', () {
    VoiceLetter letterOf(Duration length) => VoiceLetter(
      wire: Uint8List(length.inSeconds * 88),
      frames: length.inMilliseconds ~/ 40,
      length: length,
      pcmBytes: length.inMilliseconds * 16,
      elapsed: length,
    );

    test(
      'the 30 s cap hands its letter over instead of discarding it',
      () async {
        // The bug that cost session 7GH7AO its whole 120 s window: the cap
        // timer ran stop(), encoded a good letter, dropped it on the floor,
        // and the person's later tap got null back — reported to them as
        // "too short or off-rate".
        final peer = JourneyPeer();
        final recording = _FakeRecording(
          letter: letterOf(const Duration(seconds: 30)),
        );
        peer.newRecording = () => recording;
        await peer.toggleRecording();
        expect(peer.recordState.value, VoiceRecordState.recording);
        recording.elapsed = voiceLetterMaxLength;
        recording.fireCap();
        expect(
          peer.voiceLetter.value,
          isNotNull,
          reason: 'the cap keeps the letter it just encoded',
        );
        expect(peer.voiceLetter.value!.length, const Duration(seconds: 30));
        expect(peer.recordState.value, VoiceRecordState.recorded);
        final alert = peer.voiceAlert.value;
        expect(alert, isNotNull);
        expect(
          alert!.isError,
          isFalse,
          reason: 'the cap is a success, not a fault',
        );
        expect(alert.message, contains('Maximum 30s reached'));
      },
    );

    test(
      'a tap while the microphone is opening opens no second recorder',
      () async {
        final peer = JourneyPeer();
        var created = 0;
        peer.newRecording = () {
          created++;
          return _FakeRecording(
            letter: letterOf(const Duration(seconds: 5)),
            startDelay: const Duration(milliseconds: 20),
          );
        };
        final first = peer.toggleRecording();
        expect(peer.recordState.value, VoiceRecordState.starting);
        final second = peer.toggleRecording(); // the impatient second tap
        await Future.wait<void>([first, second]);
        expect(
          created,
          1,
          reason:
              'the second tap joined the transition instead of starting one',
        );
        expect(peer.recordState.value, VoiceRecordState.recording);
        await peer.toggleRecording(); // release the microphone and the ticker
      },
    );

    test(
      'a refused recording raises a banner the person must dismiss',
      () async {
        final peer = JourneyPeer();
        final recording = _FakeRecording(refusal: VoiceLetterRefusal.tooShort)
          ..elapsed = const Duration(milliseconds: 400);
        peer.newRecording = () => recording;
        await peer.toggleRecording(); // record
        await peer.toggleRecording(); // stop
        expect(peer.voiceLetter.value, isNull);
        expect(peer.recordState.value, VoiceRecordState.idle);
        final alert = peer.voiceAlert.value;
        expect(alert, isNotNull);
        expect(alert!.isError, isTrue);
        expect(
          alert.message,
          contains('400 ms'),
          reason: 'the refusal names what was captured, not a lumped sentence',
        );
        peer.dismissVoiceAlert();
        expect(peer.voiceAlert.value, isNull);
      },
    );

    test(
      'a microphone that will not open says so where the button is',
      () async {
        final peer = JourneyPeer();
        peer.newRecording = () => _FakeRecording(
          startError: VoiceLetterUnavailable(
            'microphone permission not granted',
          ),
        );
        await peer.toggleRecording();
        expect(peer.recordState.value, VoiceRecordState.idle);
        expect(peer.voiceAlert.value, isNotNull);
        expect(peer.voiceAlert.value!.isError, isTrue);
        expect(
          peer.voiceAlert.value!.message,
          contains('microphone permission not granted'),
        );
      },
    );

    test('finalizeRecording waits out an encode already in flight', () async {
      final peer = JourneyPeer();
      peer.newRecording = () => _FakeRecording(
        letter: letterOf(const Duration(seconds: 12)),
        stopDelay: const Duration(milliseconds: 30),
      );
      await peer.toggleRecording();
      unawaited(peer.toggleRecording()); // the Stop tap, still encoding
      expect(peer.recordState.value, VoiceRecordState.stopping);
      expect(peer.voiceLetter.value, isNull, reason: 'not encoded yet');
      await peer.finalizeRecording();
      expect(
        peer.voiceLetter.value,
        isNotNull,
        reason: 'the window reads the letter after the encode, not during it',
      );
    });

    test(
      'finalizeRecording with nothing running starts no recording',
      () async {
        final peer = JourneyPeer();
        var created = 0;
        peer.newRecording = () {
          created++;
          return _FakeRecording();
        };
        await peer.finalizeRecording();
        expect(created, 0);
        expect(peer.recordState.value, VoiceRecordState.idle);
      },
    );

    test('the button names every state it can be in', () {
      expect(
        voiceRecordButtonLabel(VoiceRecordState.idle, Duration.zero),
        'Record (≤30s)',
      );
      expect(
        voiceRecordButtonLabel(VoiceRecordState.starting, Duration.zero),
        'Opening microphone…',
      );
      expect(
        voiceRecordButtonLabel(
          VoiceRecordState.recording,
          const Duration(seconds: 7),
        ),
        'STOP • 0:07 / 0:30',
      );
      expect(
        voiceRecordButtonLabel(VoiceRecordState.stopping, Duration.zero),
        'Encoding…',
      );
      expect(
        voiceRecordButtonLabel(
          VoiceRecordState.recorded,
          const Duration(seconds: 65),
        ),
        'Recorded 1:05 — tap to redo',
      );
      // Idle and recording used to read the same four words: the old button
      // rendered `voiceLetter`, which is null in both states.
      expect(
        voiceRecordButtonLabel(VoiceRecordState.idle, Duration.zero),
        isNot(
          voiceRecordButtonLabel(VoiceRecordState.recording, Duration.zero),
        ),
      );
    });

    testWidgets('the failure is on the screen, not only in the event log', (
      tester,
    ) async {
      final peer = JourneyPeer();
      peer.newRecording = () =>
          _FakeRecording(refusal: VoiceLetterRefusal.tooShort)
            ..elapsed = const Duration(milliseconds: 300);
      await tester.pumpWidget(JourneyPeerApp(peer));
      expect(find.byKey(const Key('journey-peer-voice-alert')), findsNothing);
      await peer.toggleRecording();
      await peer.toggleRecording();
      await tester.pump();
      expect(find.byKey(const Key('journey-peer-voice-alert')), findsOneWidget);
      // The same sentence is also in the scrolling event log below — that
      // copy is the one nobody reads, which is why the banner exists.
      final banner = tester.widget<Text>(
        find.byKey(const Key('journey-peer-voice-alert-text')),
      );
      expect(banner.data, contains('Too short'));
      expect(banner.style!.fontSize, 18, reason: 'legible at arm\'s length');
      await tester.tap(
        find.byKey(const Key('journey-peer-voice-alert-dismiss')),
      );
      await tester.pump();
      expect(
        find.byKey(const Key('journey-peer-voice-alert')),
        findsNothing,
        reason: 'only a tap clears it — no timeout, no next event',
      );
    });
  });
}

/// A recording with no microphone, so the peer's state machine can be driven
/// in a unit test. Real capture needs a device and is not simulated here.
class _FakeRecording implements VoiceRecording {
  _FakeRecording({
    this.letter,
    this.refusal,
    this.startError,
    this.startDelay = Duration.zero,
    this.stopDelay = Duration.zero,
  });

  final VoiceLetter? letter;
  final Object? startError;
  final Duration startDelay;
  final Duration stopDelay;

  @override
  VoiceLetterRefusal? refusal;

  @override
  void Function(VoiceLetter? letter, VoiceLetterRefusal? refusal)? onCapReached;

  @override
  Duration elapsed = Duration.zero;

  @override
  int pcmBytes = 0;

  @override
  String? stopError;

  @override
  Future<void> start() async {
    if (startDelay > Duration.zero) await Future<void>.delayed(startDelay);
    final error = startError;
    if (error != null) throw error;
  }

  @override
  Future<VoiceLetter?> stop() async {
    if (stopDelay > Duration.zero) await Future<void>.delayed(stopDelay);
    return letter;
  }

  /// What the 30 s cap does now: hand the letter over, not drop it.
  void fireCap() => onCapReached?.call(letter, refusal);
}
