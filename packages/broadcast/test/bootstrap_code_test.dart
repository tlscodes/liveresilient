import 'dart:typed_data';

import 'package:broadcast/broadcast.dart';
import 'package:clock/clock.dart';
import 'package:test/test.dart';

void main() {
  final key = Uint8List.fromList(List.generate(32, (i) => (i * 7 + 3) & 0xFF));

  BootstrapCode code({String host = 'relay-one.example'}) =>
      BootstrapCode(host: host, rootPublicKey: key);

  group('size', () {
    test('a whole code fits on one written line', () {
      // The claim the bootstrap story rests on: this has to be something a
      // person can photograph, print, or read out.
      final text = code().encode();
      expect(code().encodeBytes().length, 2 + 17 + 32 + 2);
      expect(text.replaceAll('-', '').length, lessThan(100));
    });

    test('grouping is for the reader and is not part of the code', () {
      final grouped = code().encode();
      expect(grouped, contains('-'));
      expect(BootstrapCode.parse(grouped), code());
      expect(BootstrapCode.parse(code().encode(grouped: false)), code());
    });
  });

  group('round trip', () {
    test('recovers the relay and the author key exactly', () {
      final parsed = BootstrapCode.parse(code().encode());
      expect(parsed, isNotNull);
      expect(parsed!.host, 'relay-one.example');
      expect(parsed.rootPublicKey, key);
      expect(parsed.origin.toString(), 'https://relay-one.example');
      expect(parsed.authorId, authorIdFor(key));
    });

    test('is case insensitive and forgives the separators people add', () {
      final text = code().encode();
      for (final variant in [
        text.toLowerCase(),
        text.replaceAll('-', ' '),
        text.replaceAll('-', ''),
        '${text.substring(0, 8)}\n${text.substring(8)}',
      ]) {
        expect(
          BootstrapCode.parse(variant),
          code(),
          reason: 'must accept "${variant.substring(0, 12)}..."',
        );
      }
    });

    test('accepts the characters a person says instead of the right ones', () {
      // Someone reading aloud will say O for zero and I for one; the
      // alphabet excludes those precisely so they can be mapped back.
      final text = code().encode(grouped: false);
      final spoken = text.replaceAll('0', 'O').replaceAll('1', 'I');
      expect(BootstrapCode.parse(spoken), code());
    });

    test('the binary form round-trips too, for a scanned code', () {
      expect(BootstrapCode.decodeBytes(code().encodeBytes()), code());
    });
  });

  group('a wrong code produces nothing, never another author', () {
    test('one altered character fails the checksum', () {
      // The failure that matters: silently resolving to a different key
      // would have a reader follow an author they did not mean to.
      final text = code().encode(grouped: false);
      var caught = 0;
      for (var i = 0; i < text.length; i++) {
        final original = text[i];
        final replacement = original == 'A' ? 'B' : 'A';
        final broken = text.replaceRange(i, i + 1, replacement);
        final parsed = BootstrapCode.parse(broken);
        if (parsed == null) {
          caught += 1;
        } else {
          expect(
            parsed,
            isNot(code()),
            reason: 'position $i must not resolve to a different code silently',
          );
        }
      }
      // A 16-bit checksum catches essentially every single-character slip.
      expect(caught / text.length, greaterThan(0.99));
    });

    test('a truncated or padded code is refused', () {
      final text = code().encode(grouped: false);
      expect(BootstrapCode.parse(text.substring(0, text.length - 2)), isNull);
      expect(
        BootstrapCode.parse(
          '$text'
          'AAAA',
        ),
        isNull,
      );
    });

    test('a character outside the alphabet is refused', () {
      expect(BootstrapCode.parse('${code().encode()}!'), isNull);
      expect(BootstrapCode.parse(''), isNull);
    });

    test('an unknown version is refused', () {
      final bytes = code().encodeBytes()..[0] = 9;
      expect(BootstrapCode.decodeBytes(bytes), isNull);
    });

    test('a declared host length that does not match is refused', () {
      final bytes = code().encodeBytes()..[1] = 5;
      expect(BootstrapCode.decodeBytes(bytes), isNull);
    });

    test('a runt buffer is refused', () {
      expect(BootstrapCode.decodeBytes(Uint8List(10)), isNull);
    });
  });

  group('construction', () {
    test('refuses a host that is not a hostname', () {
      for (final host in [
        '',
        'Relay.Example',
        'relay example',
        'https://relay.example',
        'relay/../x',
        'a' * (maxBootstrapHostLength + 1),
      ]) {
        expect(
          () => BootstrapCode(host: host, rootPublicKey: key),
          throwsArgumentError,
          reason: 'must refuse "$host"',
        );
      }
    });

    test('refuses a key that is not an Ed25519 public key', () {
      expect(
        () => BootstrapCode(host: 'a.example', rootPublicKey: Uint8List(31)),
        throwsArgumentError,
      );
    });

    test('equality is by value', () {
      expect(code(), code());
      expect(code().hashCode, code().hashCode);
      expect(code(host: 'other.example'), isNot(code()));
    });

    test('toString names the author without spelling out the key', () {
      expect(code().toString(), contains('relay-one.example'));
      expect(code().toString(), contains(hexEncode(authorIdFor(key))));
    });
  });

  test('a code is enough to read an author end to end', () async {
    // The whole bootstrap path: a person carries this one string, and the
    // device that receives it can verify everything that follows.
    final t0 = DateTime.utc(2026, 7, 28, 12);
    final root = await CryptographyBroadcastSigner.generate();
    final publisher = await withClock(
      Clock.fixed(t0),
      () => BroadcastPublisher.create(rootSigner: root),
    );
    final relay = InMemoryBroadcastRelay(name: 'relay-one.example');
    await withClock(Clock.fixed(t0), () async {
      await publisher.pushTo(
        relay,
        await publisher.publish(
          text: Uint8List.fromList('the first message'.codeUnits),
        ),
      );
    });

    final carried = BootstrapCode(
      host: 'relay-one.example',
      rootPublicKey: root.publicKey,
    ).encode();

    // Everything from here uses only what the code carried.
    final scanned = BootstrapCode.parse(carried)!;
    final reader = BroadcastReader(
      rootPublicKey: scanned.rootPublicKey,
      relays: [relay],
    );
    await withClock(
      Clock.fixed(t0),
      () => reader.adoptCertificate(publisher.certificate.encoded),
    );
    final result = await withClock(
      Clock.fixed(t0.add(const Duration(minutes: 1))),
      () => reader.fetchNext(),
    );
    expect(result.isDelivered, isTrue);
    expect(
      String.fromCharCodes(
        (await reader.fetchLayer(result.descriptor!, LayerFlag.text))!,
      ),
      'the first message',
    );
  });
}
