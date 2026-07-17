import os

filepath = 'apps/reference_app/lib/src/call_session.dart'
with open(filepath, 'r') as f:
    content = f.read()

# اضافه کردن ایمپورت فایل جدید به صورت نسبی
import_line = "import 'ws_connector.dart';\n"
if import_line not in content:
    content = content.replace(
        "import 'package:signaling/signaling.dart';",
        "import 'package:signaling/signaling.dart';\nimport 'ws_connector.dart';"
    )

# بازنویسی بدنه متد بیلد سشن برای پذیرش قلاب‌های اختیاری
old_func = """CallSessionHandle buildWebRtcCallSession({
  required Uri endpoint,
  required String callId,
  required CallRole role,
}) {
  final client = SignalingClient(
    endpoint: endpoint,
    localKeyId: '${role.name}-key',
    connector: devLoopbackWsConnector(),
  );"""

new_func = """CallSessionHandle buildWebRtcCallSession({
  required Uri endpoint,
  required String callId,
  required CallRole role,
  String? Function(String host)? resolveAddress,
  String Function(Uri uri)? proxyResolver,
  void Function(HttpClient client)? proxyConfigurator,
  SecurityContext? securityContext,
}) {
  final client = SignalingClient(
    endpoint: endpoint,
    localKeyId: '${role.name}-key',
    connector: (uri) async {
      final socket = await connectWebSocketWithCustomRules(
        uri,
        hostResolver: resolveAddress,
        proxyResolver: proxyResolver,
        proxyConfigurator: proxyConfigurator,
        securityContext: securityContext,
      );
      return _IoSignalingSocket(socket);
    },
  );"""

if old_func in content:
    content = content.replace(old_func, new_func)
    print("Success: buildWebRtcCallSession updated!")
else:
    print("Warning: exact function signature match not found.")

with open(filepath, 'w') as f:
    f.write(content)
