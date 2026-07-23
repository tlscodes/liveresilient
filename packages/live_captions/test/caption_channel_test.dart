/// Caption channels: invite parsing (id / app link / web link), the
/// role-enforced publish rule, per-member language fan-out through the
/// real pipeline, and heartbeat presence.
library;

import 'package:live_captions/live_captions.dart';
import 'package:test/test.dart';

TranscriptSegment seg(int seq, String text, {String lang = 'en'}) =>
    TranscriptSegment(
      id: 's$seq',
      seq: seq,
      lang: lang,
      text: text,
      isFinal: true,
      startMs: seq * 1000,
    );

ChannelMember host({String lang = 'en'}) => ChannelMember(
  id: 'host-1',
  name: 'Host',
  role: ChannelRole.host,
  language: lang,
  lastSeen: DateTime.utc(2026),
);

void main() {
  group('ChannelInvite.parse', () {
    test('accepts a bare 6-digit code (the old login-screen entry)', () {
      final invite = ChannelInvite.parse('123456');
      expect(invite!.channelId, '123456');
      expect(invite.language, isNull);
    });

    test('accepts a readable slug', () {
      expect(
        ChannelInvite.parse('friday-standup')!.channelId,
        'friday-standup',
      );
    });

    test('accepts the app deeplink with a language', () {
      final invite = ChannelInvite.parse('vck://captions/123456?lang=fa');
      expect(invite!.channelId, '123456');
      expect(invite.language, 'fa');
    });

    test('accepts the https web link', () {
      final invite = ChannelInvite.parse('https://vck.app/c/room-42?lang=es');
      expect(invite!.channelId, 'room-42');
      expect(invite.language, 'es');
    });

    test('rejects junk, wrong hosts, and invalid ids', () {
      expect(ChannelInvite.parse(''), isNull);
      expect(ChannelInvite.parse('ab'), isNull); // too short
      expect(ChannelInvite.parse('has spaces'), isNull);
      expect(ChannelInvite.parse('vck://other/123456'), isNull);
      expect(ChannelInvite.parse('https://vck.app/x/123456'), isNull);
      expect(ChannelInvite.parse('ftp://vck.app/c/123456'), isNull);
    });

    test('round-trips through both generated link forms', () {
      final invite = ChannelInvite(channelId: 'room-42', language: 'fa');
      expect(
        ChannelInvite.parse(invite.toAppLink().toString())!.channelId,
        'room-42',
      );
      final web = ChannelInvite.parse(invite.toWebLink().toString())!;
      expect(web.channelId, 'room-42');
      expect(web.language, 'fa');
    });
  });

  group('CaptionChannel', () {
    test('join lands as listener; listeners cannot publish; host promotion '
        'unlocks publishing (the enforced force-mute rule)', () async {
      final channel = CaptionChannel(
        channelId: '123456',
        host: host(),
        translator: const IdentityTranslator(),
      );
      await channel.join(memberId: 'u2', name: 'Guest', language: 'fa');

      expect(
        () => channel.addSegment('u2', seg(0, 'hi')),
        throwsStateError,
        reason: 'listeners are read-only',
      );

      channel.setRole(
        byMemberId: 'host-1',
        memberId: 'u2',
        role: ChannelRole.speaker,
      );
      channel.addSegment('u2', seg(0, 'hi')); // now legal

      expect(
        () => channel.setRole(
          byMemberId: 'u2',
          memberId: 'host-1',
          role: ChannelRole.listener,
        ),
        throwsStateError,
        reason: 'only the host manages roles',
      );
      await channel.close();
    });

    test('captions fan out per member in each member\'s language, driven by '
        'the invite\'s lang parameter', () async {
      final channel = CaptionChannel(
        channelId: '123456',
        host: host(),
        translator: const FixedMapTranslator({'fa:hello': 'سلام'}),
      );
      final invite = ChannelInvite.parse('vck://captions/123456?lang=fa');
      await channel.join(memberId: 'u2', name: 'مهمان', invite: invite);

      final got = <MemberCaption>[];
      channel.memberCaptions.listen(got.add);

      channel.addSegment('host-1', seg(0, 'hello'));
      await pumpEventQueue();

      expect(got, hasLength(2));
      final byMember = {for (final c in got) c.memberId: c.text};
      expect(byMember['host-1'], 'hello'); // source language viewer
      expect(byMember['u2'], 'سلام'); // fa viewer gets the translation
      await channel.close();
    });

    test('heartbeat keeps a member alive; expireStale removes the silent '
        'one and the channel keeps working without its host', () async {
      var nowMs = 0;
      DateTime now() => DateTime.fromMillisecondsSinceEpoch(nowMs);
      final channel = CaptionChannel(
        channelId: '123456',
        host: ChannelMember(
          id: 'host-1',
          name: 'Host',
          role: ChannelRole.host,
          language: 'en',
          lastSeen: now(),
        ),
        translator: const IdentityTranslator(),
        heartbeatTimeout: const Duration(seconds: 30),
        now: now,
      );
      await channel.join(memberId: 'u2', name: 'Guest', language: 'en');
      channel.setRole(
        byMemberId: 'host-1',
        memberId: 'u2',
        role: ChannelRole.speaker,
      );

      nowMs = 20000;
      channel.heartbeat('u2'); // u2 stays fresh; host goes silent
      nowMs = 40000;
      final expired = await channel.expireStale();

      expect(expired.map((m) => m.id), ['host-1']);
      expect(channel.members.map((m) => m.id), ['u2']);

      // Survival rule: no host, captions still flow.
      final got = <MemberCaption>[];
      channel.memberCaptions.listen(got.add);
      channel.addSegment('u2', seg(0, 'still here'));
      await pumpEventQueue();
      expect(got.single.text, 'still here');
      await channel.close();
    });

    test('a new member\'s language extends the pipeline targets; leave '
        'shrinks them', () async {
      final channel = CaptionChannel(
        channelId: '123456',
        host: host(),
        translator: const IdentityTranslator(),
      );
      expect(channel.activeLanguages, {'en'});
      await channel.join(memberId: 'u2', name: 'G', language: 'fa');
      expect(channel.activeLanguages, {'en', 'fa'});
      await channel.leave('u2');
      expect(channel.activeLanguages, {'en'});
      await channel.close();
    });

    test('roster stream emits on every membership change', () async {
      final channel = CaptionChannel(
        channelId: '123456',
        host: host(),
        translator: const IdentityTranslator(),
      );
      final rosters = <List<ChannelMember>>[];
      channel.rosterChanges.listen(rosters.add);

      await channel.join(memberId: 'u2', name: 'G', language: 'fa');
      await channel.leave('u2');
      await pumpEventQueue();

      expect(rosters, hasLength(2));
      expect(rosters.first.map((m) => m.id), contains('u2'));
      expect(rosters.last.map((m) => m.id), isNot(contains('u2')));
      await channel.close();
    });

    test('validation: bad channel id and non-host founder throw', () {
      expect(
        () => CaptionChannel(
          channelId: 'x',
          host: host(),
          translator: const IdentityTranslator(),
        ),
        throwsArgumentError,
      );
      expect(
        () => CaptionChannel(
          channelId: '123456',
          host: ChannelMember(
            id: 'u1',
            name: 'NotHost',
            role: ChannelRole.listener,
            language: 'en',
            lastSeen: DateTime.utc(2026),
          ),
          translator: const IdentityTranslator(),
        ),
        throwsArgumentError,
      );
    });
  });
}
