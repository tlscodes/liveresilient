import 'dart:typed_data';

import 'package:broadcast/broadcast.dart';
import 'package:test/test.dart';

void main() {
  const verifier = CryptographyBroadcastVerifier();
  final t0 = DateTime.utc(2026, 7, 28, 12);
  final origins = [
    Uri.parse('https://relay-one.example'),
    Uri.parse('https://relay-two.example'),
    Uri.parse('http://192.0.2.7:8080'),
  ];

  late CryptographyBroadcastSigner root;

  setUp(() async => root = await CryptographyBroadcastSigner.generate());

  Future<RelayDirectory> issue({
    List<Uri>? relays,
    int seq = 1,
    Duration validity = const Duration(days: 90),
  }) => RelayDirectory.issue(
    rootSigner: root,
    origins: relays ?? origins,
    seq: seq,
    notAfter: t0.add(validity),
  );

  Future<RelayDirectory?> verify(
    Uint8List encoded, {
    DateTime? now,
    int? knownSeq,
    Uint8List? key,
    void Function(DirectoryRejection)? onReject,
  }) => RelayDirectory.verify(
    encoded: encoded,
    rootPublicKey: key ?? root.publicKey,
    verifier: verifier,
    now: now ?? t0,
    knownSeq: knownSeq,
    onReject: onReject,
  );

  group('size', () {
    test('three relays fit in a couple of hundred bytes', () async {
      // The claim the whole design leans on: this list travels by
      // photograph, by print, by memory card. Arithmetic keeps it honest.
      final directory = await issue();
      expect(directory.encoded.length, lessThan(200));
      expect(
        directory.encoded.length,
        RelayDirectory.sizeFor([
          'https://relay-one.example',
          'https://relay-two.example',
          'http://192.0.2.7:8080',
        ]),
      );
    });

    test(
      'even the largest possible directory stays well under a kilobyte',
      () async {
        final many = [
          for (var i = 0; i < maxDirectoryRelays; i++)
            Uri.parse('https://${'r' * 40}$i.example'),
        ];
        final directory = await issue(relays: many);
        expect(directory.origins, hasLength(maxDirectoryRelays));
        expect(directory.encoded.length, lessThan(700));
      },
    );
  });

  group('round trip', () {
    test('verifies and returns the origins in order', () async {
      final directory = await issue();
      final parsed = await verify(directory.encoded);
      expect(parsed, isNotNull);
      expect(parsed!.seq, 1);
      expect(parsed.notAfter, t0.add(const Duration(days: 90)));
      expect(parsed.origins.map((u) => u.toString()), [
        'https://relay-one.example',
        'https://relay-two.example',
        'http://192.0.2.7:8080',
      ]);
    });

    test('a default port is dropped and a non-default one kept', () async {
      final directory = await issue(
        relays: [
          Uri.parse('https://a.example:443'),
          Uri.parse('https://b.example:8443'),
        ],
      );
      final parsed = await verify(directory.encoded);
      expect(parsed!.origins.map((u) => u.toString()), [
        'https://a.example',
        'https://b.example:8443',
      ]);
    });

    test('a path, query or fragment on an origin is discarded', () async {
      final directory = await issue(
        relays: [Uri.parse('https://a.example/some/path?q=1#frag')],
      );
      expect(
        (await verify(directory.encoded))!.origins.single.toString(),
        'https://a.example',
      );
    });
  });

  group('refusals', () {
    test('a different root key does not verify it', () async {
      final other = await CryptographyBroadcastSigner.generate();
      final reasons = <DirectoryRejection>[];
      expect(
        await verify(
          (await issue()).encoded,
          key: other.publicKey,
          onReject: reasons.add,
        ),
        isNull,
      );
      expect(reasons, [DirectoryRejection.badSignature]);
    });

    test('every body byte is covered by the signature', () async {
      final directory = await issue();
      for (var i = 0; i < directory.encoded.length - 64; i++) {
        final tampered = Uint8List.fromList(directory.encoded)..[i] ^= 0x01;
        expect(
          await verify(tampered),
          isNull,
          reason: 'byte $i must not verify',
        );
      }
    });

    test('an expired directory is refused', () async {
      final directory = await issue(validity: const Duration(days: 1));
      final reasons = <DirectoryRejection>[];
      expect(
        await verify(
          directory.encoded,
          now: t0.add(const Duration(days: 1, seconds: 1)),
          onReject: reasons.add,
        ),
        isNull,
      );
      expect(reasons, [DirectoryRejection.expired]);
    });

    test('a validity beyond what a reader grants is refused', () async {
      final directory = await RelayDirectory.issue(
        rootSigner: root,
        origins: origins,
        seq: 1,
        notAfter: t0.add(const Duration(days: 800)),
      );
      final reasons = <DirectoryRejection>[];
      expect(await verify(directory.encoded, onReject: reasons.add), isNull);
      expect(reasons, [DirectoryRejection.validityTooLong]);
    });

    test(
      'an older or equal sequence number is refused as a rollback',
      () async {
        // Without this, any captured older list could be replayed forever to
        // pin a reader to relays the author has abandoned.
        final old = await issue(seq: 4);
        for (final known in [4, 5, 99]) {
          final reasons = <DirectoryRejection>[];
          expect(
            await verify(old.encoded, knownSeq: known, onReject: reasons.add),
            isNull,
            reason: 'seq 4 must not replace known $known',
          );
          expect(reasons, [DirectoryRejection.rolledBack]);
        }
        expect(await verify(old.encoded, knownSeq: 3), isNotNull);
      },
    );

    test('an unknown version is refused', () async {
      final bad = Uint8List.fromList((await issue()).encoded)..[0] = 9;
      final reasons = <DirectoryRejection>[];
      expect(await verify(bad, onReject: reasons.add), isNull);
      expect(reasons, [DirectoryRejection.unsupportedVersion]);
    });

    test('a count of zero or above the ceiling is refused', () async {
      final encoded = (await issue()).encoded;
      final none = Uint8List.fromList(encoded)..[1] = 0;
      final reasons = <DirectoryRejection>[];
      expect(await verify(none, onReject: reasons.add), isNull);
      expect(reasons, [DirectoryRejection.noRelays]);

      final many = Uint8List.fromList(encoded)..[1] = maxDirectoryRelays + 1;
      final more = <DirectoryRejection>[];
      expect(await verify(many, onReject: more.add), isNull);
      expect(more, [DirectoryRejection.tooManyRelays]);
    });

    test('trailing or missing bytes are refused', () async {
      final encoded = (await issue()).encoded;
      for (final variant in [
        Uint8List.fromList([...encoded, 0]),
        Uint8List.fromList(encoded.sublist(0, encoded.length - 1)),
      ]) {
        final reasons = <DirectoryRejection>[];
        expect(await verify(variant, onReject: reasons.add), isNull);
        expect(reasons, [DirectoryRejection.malformed]);
      }
    });

    test(
      'a non-canonical origin inside a valid signature is refused',
      () async {
        // Signed by the author, so the signature passes — and it is still
        // refused, because the bytes a reader verifies must be the bytes it
        // acts on.
        final body = WireBuilderForTest.directoryBody(
          seq: 1,
          notAfter: t0.add(const Duration(days: 10)),
          origins: ['https://a.example:443'],
        );
        final signed = await WireBuilderForTest.sign(root, body);
        final reasons = <DirectoryRejection>[];
        expect(await verify(signed, onReject: reasons.add), isNull);
        expect(reasons, [DirectoryRejection.badOrigin]);
      },
    );

    test('a duplicate origin is refused', () async {
      final body = WireBuilderForTest.directoryBody(
        seq: 1,
        notAfter: t0.add(const Duration(days: 10)),
        origins: ['https://a.example', 'https://a.example'],
      );
      final signed = await WireBuilderForTest.sign(root, body);
      final reasons = <DirectoryRejection>[];
      expect(await verify(signed, onReject: reasons.add), isNull);
      expect(reasons, [DirectoryRejection.duplicateOrigin]);
    });

    test('a zero-length origin is refused', () async {
      final body = WireBuilderForTest.directoryBody(
        seq: 1,
        notAfter: t0.add(const Duration(days: 10)),
        origins: [''],
      );
      final signed = await WireBuilderForTest.sign(root, body);
      final reasons = <DirectoryRejection>[];
      expect(await verify(signed, onReject: reasons.add), isNull);
      expect(reasons, [DirectoryRejection.badOrigin]);
    });
  });

  group('issuing argument checks', () {
    test('refuses an empty list, too many, and a non-http origin', () {
      expect(() => issue(relays: const []), throwsArgumentError);
      expect(
        () => issue(
          relays: [
            for (var i = 0; i <= maxDirectoryRelays; i++)
              Uri.parse('https://r$i.example'),
          ],
        ),
        throwsArgumentError,
      );
      expect(
        () => issue(relays: [Uri.parse('ftp://a.example')]),
        throwsArgumentError,
      );
    });

    test('refuses an origin longer than the field, and one named twice', () {
      expect(
        () => issue(relays: [Uri.parse('https://${'a' * 80}.example')]),
        throwsArgumentError,
      );
      expect(
        () => issue(
          relays: [
            Uri.parse('https://a.example'),
            Uri.parse('https://a.example:443'),
          ],
        ),
        throwsArgumentError,
      );
    });
  });

  group('RelayDirectoryStore', () {
    test('adopts a first directory and then only newer ones', () async {
      final store = RelayDirectoryStore();
      expect(store.current, isNull);
      expect(store.knownSeq, isNull);

      final first = await issue(seq: 2);
      expect(
        await store.adopt(
          encoded: first.encoded,
          rootPublicKey: root.publicKey,
          verifier: verifier,
          now: t0,
        ),
        isTrue,
      );
      expect(store.knownSeq, 2);

      // Same sequence number, different content: refused.
      final replay = await issue(
        seq: 2,
        relays: [Uri.parse('https://x.example')],
      );
      final reasons = <DirectoryRejection>[];
      expect(
        await store.adopt(
          encoded: replay.encoded,
          rootPublicKey: root.publicKey,
          verifier: verifier,
          now: t0,
          onReject: reasons.add,
        ),
        isFalse,
      );
      expect(reasons, [DirectoryRejection.rolledBack]);
      expect(store.current!.origins, hasLength(3));

      final newer = await issue(
        seq: 3,
        relays: [Uri.parse('https://x.example')],
      );
      expect(
        await store.adopt(
          encoded: newer.encoded,
          rootPublicKey: root.publicKey,
          verifier: verifier,
          now: t0,
        ),
        isTrue,
      );
      expect(store.current!.origins.single.host, 'x.example');
    });

    test('falls back rather than stranding a reader', () async {
      // A reader whose directory expired loses reach, not the ability to
      // read at all.
      final fallback = [Uri.parse('https://built-in.example')];
      final store = RelayDirectoryStore();
      expect(store.originsAt(t0, fallback: fallback), fallback);

      final directory = await issue(validity: const Duration(days: 5));
      await store.adopt(
        encoded: directory.encoded,
        rootPublicKey: root.publicKey,
        verifier: verifier,
        now: t0,
      );
      expect(store.originsAt(t0, fallback: fallback), hasLength(3));
      expect(
        store.originsAt(
          t0.add(const Duration(days: 5, seconds: 1)),
          fallback: fallback,
        ),
        fallback,
      );
    });

    test('garbage is not adopted', () async {
      final store = RelayDirectoryStore();
      expect(
        await store.adopt(
          encoded: Uint8List(12),
          rootPublicKey: root.publicKey,
          verifier: verifier,
          now: t0,
        ),
        isFalse,
      );
      expect(store.current, isNull);
    });
  });
}

/// Builds directory bytes the public API refuses to produce, so the
/// verifier's own checks can be exercised on genuinely signed input.
class WireBuilderForTest {
  static Uint8List directoryBody({
    required int seq,
    required DateTime notAfter,
    required List<String> origins,
  }) {
    final out = <int>[
      directoryVersion,
      origins.length,
      (seq >> 24) & 0xFF,
      (seq >> 16) & 0xFF,
      (seq >> 8) & 0xFF,
      seq & 0xFF,
    ];
    final seconds = notAfter.toUtc().millisecondsSinceEpoch ~/ 1000;
    out.addAll([
      (seconds >> 32) & 0xFF,
      (seconds >> 24) & 0xFF,
      (seconds >> 16) & 0xFF,
      (seconds >> 8) & 0xFF,
      seconds & 0xFF,
    ]);
    for (final origin in origins) {
      out
        ..add(origin.length)
        ..addAll(origin.codeUnits);
    }
    return Uint8List.fromList(out);
  }

  static Future<Uint8List> sign(BroadcastSigner signer, Uint8List body) async {
    final domain = 'vck/broadcast/relay-directory/v1\n'.codeUnits;
    final signature = await signer.sign(
      Uint8List.fromList([...domain, ...body]),
    );
    return Uint8List.fromList([...body, ...signature]);
  }
}
