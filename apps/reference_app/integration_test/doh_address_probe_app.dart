// A one-shot on-device witness for the address-literal DoH fallback.
//
// Launched on the phone with no tooling attached, it sends one ordinary TXT
// question for a public name through the SAME DohQueryTransport the valve
// uses, to each built-in endpoint (TxtQueryResolvers.publicDohEndpoints),
// and reports what came back to the journey hub. It proves one thing: the
// phone's own TLS stack accepts the service's certificate for a bare
// address and the endpoint answers RFC 8484 there. A lab witness on the
// rig's own uplink, not a claim about any other network.
//
//   flutter build ios --profile -t integration_test/doh_address_probe_app.dart \
//     --dart-define=JOURNEY_HUB_URL=http://<bridge>:8765
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:adaptive_transport/adaptive_transport.dart';
import 'package:flutter/material.dart';

const String hubUrl = String.fromEnvironment(
  'JOURNEY_HUB_URL',
  defaultValue: 'http://192.168.2.1:8765',
);
const String runId = String.fromEnvironment(
  'PROBE_RUN',
  defaultValue: 'doh-address-probe',
);
const String question = 'example.com';

final HttpClient _hub = HttpClient()
  ..connectionTimeout = const Duration(seconds: 3);

Future<void> report(Map<String, Object?> fields) async {
  final body = jsonEncode(<String, Object?>{
    'event': 'doh_address_probe',
    'run': runId,
    'at': DateTime.now().toUtc().toIso8601String(),
    ...fields,
  });
  debugPrint('DOH_PROBE $body');
  try {
    final req = await _hub
        .postUrl(Uri.parse('$hubUrl/report'))
        .timeout(const Duration(seconds: 5));
    req.headers.contentType = ContentType.json;
    req.write(body);
    final res = await req.close().timeout(const Duration(seconds: 5));
    await res.drain<void>();
  } on Object catch (error) {
    debugPrint('DOH_PROBE report failed: $error');
  }
}

/// One question to one endpoint; the fields a row needs, never the answer's
/// content.
Future<Map<String, Object?>> probe(Uri endpoint) async {
  final transport = DohQueryTransport(endpoint);
  final txid = Random().nextInt(0x10000);
  final started = DateTime.now();
  try {
    final answer = await transport.exchange(
      TxtQueryWire.buildDnsQueryPacket(txid, question),
      txid,
      const Duration(seconds: 8),
    );
    return <String, Object?>{
      'label': transport.label,
      'ok': true,
      'rcode': answer[3] & 0x0F,
      'answers': (answer[6] << 8) | answer[7],
      'bytes': answer.length,
      'ms': DateTime.now().difference(started).inMilliseconds,
    };
  } on Object catch (error) {
    return <String, Object?>{
      'label': transport.label,
      'ok': false,
      'error': '${error.runtimeType}',
      'ms': DateTime.now().difference(started).inMilliseconds,
    };
  } finally {
    transport.dispose();
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final lines = ValueNotifier<List<String>>(const ['probing…']);
  runApp(
    MaterialApp(
      home: Scaffold(
        body: SafeArea(
          child: ValueListenableBuilder<List<String>>(
            valueListenable: lines,
            builder: (context, value, _) => ListView(
              padding: const EdgeInsets.all(16),
              children: [for (final line in value) Text(line)],
            ),
          ),
        ),
      ),
    ),
  );
  final hosts = [for (final e in TxtQueryResolvers.publicDohEndpoints) e.host];
  await report(<String, Object?>{'stage': 'start', 'endpoints': hosts});
  final shown = <String>[];
  for (final endpoint in TxtQueryResolvers.publicDohEndpoints) {
    final row = await probe(endpoint);
    await report(<String, Object?>{'stage': 'row', ...row});
    shown.add('$row');
    lines.value = List.of(shown);
  }
  await report(<String, Object?>{'stage': 'done'});
}
