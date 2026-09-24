// End-to-end: TxtLetterProbe + TxtLetterCourier against the REAL Python
// responder (tools/t2/txt_query_server.py) over UDP on this machine.
//
//   dart run tool/letter_probe_e2e.dart <port> <deadPort> <letterBytes>
//
// Three resolvers: two point at the responder, one at a port nobody serves.
// Prints one PROBE line and one LETTER line; exit 0 only when the letter
// was sent through the resolver whose nonce the responder logged first.
import 'dart:io';

import 'package:adaptive_transport/adaptive_transport.dart';

Future<void> main(List<String> args) async {
  final port = int.parse(args[0]);
  final dead = int.parse(args[1]);
  final size = int.parse(args[2]);
  final transports = <TxtQueryTransport>[
    Udp53QueryTransport(HostPort(host: '127.0.0.1', port: dead)),
    Udp53QueryTransport(HostPort(host: '127.0.0.1', port: port)),
    Udp53QueryTransport(HostPort(host: '127.0.0.1', port: port)),
  ];
  final probe = TxtLetterProbe(
    domain: 'valve.test',
    transports: transports,
    timeout: const Duration(seconds: 2),
  );
  final courier = TxtLetterCourier(probe: probe);
  final letter = List<int>.generate(size, (i) => (i * 7 + 3) % 256);
  final d = await courier.send(letter);
  final p = d.probe;
  if (p != null) {
    stdout.writeln(
      'PROBE group=${p.groupId} winner=${p.winnerIndex} '
      '${p.answers.map((a) => '[${a.index} ${a.label} nonce=${a.nonce} '
          'rank=${a.rank} winner=${a.winnerNonce} err=${a.error == null ? '-' : a.error.runtimeType}]').join(' ')}',
    );
  }
  stdout.writeln(
    'LETTER route=${d.route.name} via=${d.via} bytes=$size '
    'queued=${courier.queue.length} error=${d.error}',
  );
  for (final t in transports) {
    await t.dispose();
  }
  final ok = size > TxtLetterCourier.maxLetterBytes
      ? d.route == LetterRoute.tooLarge
      : d.route == LetterRoute.sent &&
            p != null &&
            p.winnerIndex != null &&
            d.via == transports[p.winnerIndex!].label;
  exit(ok ? 0 : 1);
}
