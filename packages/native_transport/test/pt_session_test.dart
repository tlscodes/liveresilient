/// Tests run against the REAL shared library, not a fake. A binding whose
/// tests never cross the boundary proves nothing about the boundary.
///
/// The library path comes from PT_LIBRARY_PATH, or falls back to the engine
/// checkout beside this repository. When neither exists the tests are skipped
/// with a message naming what is missing — a skipped test that says why is
/// honest; a silently passing one is not.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:adaptive_transport/adaptive_transport.dart';
import 'package:native_transport/native_transport.dart';
import 'package:test/test.dart';

String? _resolveLibrary() {
  final fromEnv = Platform.environment['PT_LIBRARY_PATH'];
  if (fromEnv != null && File(fromEnv).existsSync()) return fromEnv;
  // No absolute paths: the library comes from an external build, and where it
  // sits differs per machine. PT_LIBRARY_PATH is the supported way in.
  const fallbacks = <String>[];
  for (final path in fallbacks) {
    if (File(path).existsSync()) return path;
  }
  return null;
}

void main() {
  final libraryPath = _resolveLibrary();
  if (libraryPath == null) {
    final configured = Platform.environment['PT_LIBRARY_PATH'];
    if (configured != null && configured.isNotEmpty) {
      // Explicitly pointed somewhere that does not exist: a real error.
      test('native library is available', () {
        fail('PT_LIBRARY_PATH is set to "$configured" but no file is there');
      });
      return;
    }
    // Nothing configured: this repository does not build the transport
    // library, so the surface is untested here — say so instead of failing.
    test(
      'native transport session',
      () {},
      skip:
          'no transport library configured; set PT_LIBRARY_PATH to run '
          'these tests against an external build',
    );
    return;
  }

  late PtBindings bindings;

  setUpAll(() => bindings = PtBindings.open(libraryPath));

  test('the loaded library reports ABI version 1.1', () {
    expect(bindings.abiVersion, '1.1');
  });

  test('every status code has a description', () {
    expect(bindings.describeStatus(PtStatus.ok), 'ok');
    expect(bindings.describeStatus(PtStatus.noStrategy), 'unknown strategy');
    expect(bindings.describeStatus(PtStatus.io), 'io error');
  });

  test('an unknown strategy fails with a non-empty message', () {
    expect(
      () => PtSession.open(bindings, strategy: 'no-such-strategy'),
      throwsA(
        isA<PtException>()
            .having((e) => e.status, 'status', PtStatus.noStrategy)
            .having((e) => e.message, 'message', isNotEmpty),
      ),
    );
  });

  test('an empty strategy name is rejected as an invalid argument', () {
    expect(
      () => PtSession.open(bindings, strategy: ''),
      throwsA(
        isA<PtException>().having((e) => e.status, 'status', PtStatus.invalid),
      ),
    );
  });

  test('sending before connect fails rather than silently succeeding', () {
    final session = PtSession.open(bindings, strategy: 'mock');
    addTearDown(session.dispose);
    expect(() => session.send([1, 2, 3]), throwsA(isA<PtException>()));
  });

  test('bytes round-trip through the mock strategy unchanged', () {
    final session = PtSession.open(bindings, strategy: 'mock');
    addTearDown(session.dispose);
    session.connect('127.0.0.1', 9);

    final payload = Uint8List.fromList(
      List<int>.generate(64, (i) => (i * 7) & 0xFF),
    );
    expect(session.sendAll(payload), payload.length);

    final received = session.recv(payload.length);
    expect(received, payload, reason: 'loopback must not alter the bytes');
  });

  test('a read with nothing buffered returns empty, not an error', () {
    final session = PtSession.open(bindings, strategy: 'mock');
    addTearDown(session.dispose);
    session.connect('127.0.0.1', 9);
    expect(session.recv(32), isEmpty);
  });

  test('dispose is idempotent and later use throws', () {
    final session = PtSession.open(bindings, strategy: 'mock');
    session.dispose();
    session.dispose(); // must not double-free
    expect(session.isDisposed, isTrue);
    expect(() => session.send([1]), throwsStateError);
  });

  test('the lane reports its name and survives a send round-trip', () async {
    final lane = PtNativeLane.open(libraryPath: libraryPath, strategy: 'mock');
    addTearDown(lane.dispose);
    lane.session.connect('127.0.0.1', 9);

    expect(lane.name, ptNativeLaneName);
    expect(await lane.probe(), isTrue);

    final result = await lane.send(const [9, 8, 7]);
    expect(result.delivered, isTrue);
    expect(lane.receive(capacity: 3), Uint8List.fromList([9, 8, 7]));
  });

  test('a disposed lane reports unavailable instead of throwing', () async {
    final lane = PtNativeLane.open(libraryPath: libraryPath, strategy: 'mock');
    await lane.dispose();
    expect(await lane.probe(), isFalse);
    final result = await lane.send(const [1]);
    expect(result.status, SendStatus.unavailable);
  });
}
