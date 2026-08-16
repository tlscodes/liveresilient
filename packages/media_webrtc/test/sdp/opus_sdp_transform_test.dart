import 'package:media_webrtc/src/sdp/opus_sdp_transform.dart';
import 'package:test/test.dart';

/// A minimal but realistic offer: two m-lines, a BUNDLE group, rtcp-mux, and an
/// Opus payload type that is deliberately NOT 111 — a hardcoded 111 would edit
/// the wrong codec here, which is the trap this suite exists to catch.
const _sdp = 'v=0\r\n'
    'o=- 46117 2 IN IP4 127.0.0.1\r\n'
    's=-\r\n'
    't=0 0\r\n'
    'a=group:BUNDLE 0 1\r\n'
    'm=audio 9 UDP/TLS/RTP/SAVPF 96 8\r\n'
    'c=IN IP4 0.0.0.0\r\n'
    'a=rtcp-mux\r\n'
    'a=mid:0\r\n'
    'a=rtpmap:96 opus/48000/2\r\n'
    'a=fmtp:96 minptime=10;stereo=0\r\n'
    'a=rtpmap:8 PCMA/8000\r\n'
    'm=video 9 UDP/TLS/RTP/SAVPF 100\r\n'
    'a=mid:1\r\n'
    'a=rtpmap:100 VP8/90000\r\n'
    'a=fmtp:100 x-google-start-bitrate=800\r\n';

List<String> _lines(String s) => s.split('\r\n');

String _fmtpFor(String sdp, String pt) =>
    _lines(sdp).firstWhere((l) => l.startsWith('a=fmtp:$pt '));

void main() {
  group('applyOpusPolicy', () {
    test('sets the fmtp keys on the payload type named by rtpmap, not 111', () {
      final out = applyOpusPolicy(
        _sdp,
        OpusSdpPolicy(inbandFec: true, maxAverageBitrateBps: 24000),
      );
      final fmtp = _fmtpFor(out, '96');
      expect(fmtp, contains('useinbandfec=1'));
      expect(fmtp, contains('maxaveragebitrate=24000'));
    });

    test('preserves parameters it does not own', () {
      final out = applyOpusPolicy(_sdp, OpusSdpPolicy());
      final fmtp = _fmtpFor(out, '96');
      expect(fmtp, contains('minptime=10'));
      expect(fmtp, contains('stereo=0'));
    });

    test('dtx is off unless asked for, and settable', () {
      final off = applyOpusPolicy(_sdp, OpusSdpPolicy());
      expect(_fmtpFor(off, '96'), isNot(contains('usedtx')));
      final on = applyOpusPolicy(_sdp, OpusSdpPolicy(silence: OpusSilenceHandling.discontinuous));
      expect(_fmtpFor(on, '96'), contains('usedtx=1'));
    });

    test('is idempotent — renegotiation runs it again', () {
      final policy = OpusSdpPolicy(maxAverageBitrateBps: 16000, ptimeMs: 60);
      final once = applyOpusPolicy(_sdp, policy);
      expect(applyOpusPolicy(once, policy), equals(once));
    });

    test('touches nothing outside the audio section', () {
      final out = applyOpusPolicy(
        _sdp,
        OpusSdpPolicy(maxAverageBitrateBps: 24000),
      );
      final before = _lines(_sdp);
      final after = _lines(out);
      for (final l in [
        'a=group:BUNDLE 0 1',
        'a=rtcp-mux',
        'm=video 9 UDP/TLS/RTP/SAVPF 100',
        'a=fmtp:100 x-google-start-bitrate=800',
        'a=rtpmap:8 PCMA/8000',
      ]) {
        expect(after, contains(l), reason: '$l must survive untouched');
      }
      // The only permitted growth is the ptime line; here there is none.
      expect(after.length, equals(before.length));
      expect(after.where((l) => l.startsWith('m=')).length,
          equals(before.where((l) => l.startsWith('m=')).length));
    });

    test('adds an fmtp line when the offer has none', () {
      final noFmtp = _sdp.replaceFirst('a=fmtp:96 minptime=10;stereo=0\r\n', '');
      final out = applyOpusPolicy(noFmtp, OpusSdpPolicy());
      expect(_fmtpFor(out, '96'), contains('useinbandfec=1'));
      // and it lands right after the rtpmap line it belongs to
      final ls = _lines(out);
      expect(ls[ls.indexOf('a=rtpmap:96 opus/48000/2') + 1],
          startsWith('a=fmtp:96 '));
    });

    test('rewrites ptime rather than appending a second one', () {
      final withPtime = _sdp.replaceFirst(
          'a=rtpmap:8 PCMA/8000\r\n', 'a=ptime:20\r\na=rtpmap:8 PCMA/8000\r\n');
      final out = applyOpusPolicy(withPtime, OpusSdpPolicy(ptimeMs: 60));
      expect(_lines(out).where((l) => l.startsWith('a=ptime:')).length, 1);
      expect(out, contains('a=ptime:60'));
    });

    test('leaves an SDP with no Opus alone', () {
      const noOpus = 'v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 8\r\n'
          'a=rtpmap:8 PCMA/8000\r\n';
      expect(applyOpusPolicy(noOpus, OpusSdpPolicy()), equals(noOpus));
    });

    test('preserves the line terminator it was given', () {
      final lf = _sdp.replaceAll('\r\n', '\n');
      final out = applyOpusPolicy(lf, OpusSdpPolicy());
      expect(out.contains('\r\n'), isFalse);
      expect(out, contains('useinbandfec=1'));
    });
  });
}
