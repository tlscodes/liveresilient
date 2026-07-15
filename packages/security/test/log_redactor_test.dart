import 'package:security/src/log_redactor.dart';
import 'package:test/test.dart';

void main() {
  group('LogRedactor.redact rule ordering', () {
    test(
      'IPv4 inside an ICE candidate line is labeled [ipv4], not [phone]',
      () {
        final result = LogRedactor.redact(
          'candidate host 192.168.1.42:54321 typ host',
        );
        expect(result, contains('[ipv4]'));
        expect(result, isNot(contains('[phone]')));
        expect(result, isNot(contains('192.168.1.42')));
      },
    );

    test('international phone number is labeled [phone]', () {
      final result = LogRedactor.redact('call me at +49 30 123456');
      expect(result, contains('[phone]'));
      expect(result, isNot(contains('123456')));
    });

    test('IPv6 address is labeled [ipv6]', () {
      final result = LogRedactor.redact(
        'peer address 2001:0db8:85a3:0000:0000:8a2e:0370:7334 connected',
      );
      expect(result, contains('[ipv6]'));
      expect(result, isNot(contains('8a2e')));
    });

    test(
      'a line with both an IPv4 address and a phone number labels both correctly',
      () {
        final result = LogRedactor.redact(
          'client 192.168.1.5 called +49 30 123456',
        );
        expect(result, contains('[ipv4]'));
        expect(result, contains('[phone]'));
        expect(result, isNot(contains('192.168.1.5')));
        expect(result, isNot(contains('123456')));
      },
    );
  });

  group('LogRedactor.redactSdp', () {
    test(
      'drops candidate lines and summarizes connection lines so no raw IP survives',
      () {
        const sdp =
            'v=0\n'
            'o=- 12345 2 IN IP4 127.0.0.1\n'
            'c=IN IP4 198.51.100.7\n'
            'a=candidate:1 1 UDP 2130706431 198.51.100.7 12345 typ host\n'
            'a=candidate:2 1 UDP 2130706431 203.0.113.9 23456 typ srflx\n'
            'a=mid:0\n';

        final result = LogRedactor.redactSdp(sdp);

        expect(result, isNot(contains('198.51.100.7')));
        expect(result, isNot(contains('203.0.113.9')));
        expect(result, isNot(contains('127.0.0.1')));
        expect(result, isNot(contains('a=candidate')));
        expect(result, contains('c=[redacted-connection]'));
        expect(result, contains('a=[2 candidate lines redacted]'));
        expect(result, contains('a=mid:0'));
      },
    );
  });
}
