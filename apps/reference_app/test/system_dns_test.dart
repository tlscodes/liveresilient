// The system-resolver channel from the Dart side: a platform answer
// becomes one HostPort on port 53; no channel, no answer or an error is
// null — never a crash, never a stale address.
import 'package:adaptive_transport/adaptive_transport.dart' show HostPort;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reference_app/src/intelligence/system_dns.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(SystemDns.channelName);

  void platformAnswers(Future<Object?> Function(MethodCall call)? handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, handler);
  }

  tearDown(() => platformAnswers(null));

  test('no channel at all (desktop, the gate): null, no crash', () async {
    final dns = SystemDns();
    expect(await dns.refresh(), isNull);
    expect(dns.current, isNull);
  });

  test('the platform names a resolver: that one, on port 53', () async {
    platformAnswers((call) async {
      expect(call.method, 'firstResolver');
      return ' 203.0.113.9 ';
    });
    final dns = SystemDns();
    const expected = HostPort(host: '203.0.113.9', port: 53);
    expect(await dns.refresh(), expected);
    expect(dns.current, expected);
  });

  test('the platform names none: null, and the earlier answer is dropped, '
      'not kept stale', () async {
    platformAnswers((_) async => '203.0.113.9');
    final dns = SystemDns();
    await dns.refresh();
    expect(dns.current, isNotNull);

    platformAnswers((_) async => null);
    expect(await dns.refresh(), isNull);
    expect(dns.current, isNull);
  });

  test('a platform error: null, no crash', () async {
    platformAnswers((_) async => throw PlatformException(code: 'boom'));
    final dns = SystemDns();
    expect(await dns.refresh(), isNull);
    expect(dns.current, isNull);
  });
}
