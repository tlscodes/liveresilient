import 'dart:typed_data';

import 'package:broadcast/broadcast.dart';
import 'package:test/test.dart';

void main() {
  final authorId = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]);

  group('DescriptorAddress', () {
    test('is predictable from author and sequence alone', () {
      // The whole point: a reader names the next post without consulting
      // any mutable index, so there is no "latest" endpoint to block.
      final address = DescriptorAddress(authorId: authorId, seq: 41);
      expect(address.path, '/a/0102030405060708/41');
      expect(address.next!.path, '/a/0102030405060708/42');
    });

    test('round-trips through its own path', () {
      final address = DescriptorAddress(authorId: authorId, seq: 7);
      final parsed = DescriptorAddress.tryParse(address.path);
      expect(parsed, address);
      expect(parsed!.seq, 7);
      expect(parsed.authorId, authorId);
    });

    test('equality and hashing are by value', () {
      final a = DescriptorAddress(authorId: authorId, seq: 3);
      final b = DescriptorAddress(
        authorId: Uint8List.fromList(authorId),
        seq: 3,
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect({a, b}.length, 1);
    });

    test('stops at the top of the sequence space rather than wrapping', () {
      // Wrapping would let a chain silently restart at genesis, which is
      // exactly the state a fork detector cannot distinguish.
      expect(DescriptorAddress(authorId: authorId, seq: maxSeq).next, isNull);
      expect(
        DescriptorAddress(authorId: authorId, seq: maxSeq - 1).next!.seq,
        maxSeq,
      );
    });

    test('rejects a second spelling of the same address', () {
      // Two paths for one post would split the cache and let the same
      // bytes be served twice under different names.
      expect(DescriptorAddress.tryParse('/a/0102030405060708/007'), isNull);
      expect(DescriptorAddress.tryParse('/a/0102030405060708/+7'), isNull);
      expect(DescriptorAddress.tryParse('/a/0102030405060708/ 7'), isNull);
    });

    test('rejects a malformed path', () {
      for (final path in [
        '',
        '/',
        '/a/0102030405060708',
        '/a/0102030405060708/1/2',
        '/b/0102030405060708/1',
        'a/0102030405060708/1',
        '/a/01020304050607/1',
        '/a/010203040506070809/1',
        '/a/zzzzzzzzzzzzzzzz/1',
        '/a/0102030405060708/-1',
        '/a/0102030405060708/x',
        '/a/0102030405060708/4294967296',
      ]) {
        expect(
          DescriptorAddress.tryParse(path),
          isNull,
          reason: 'must refuse $path',
        );
      }
    });

    test('accepts sequence zero and the maximum', () {
      expect(DescriptorAddress.tryParse('/a/0102030405060708/0')!.seq, 0);
      expect(
        DescriptorAddress.tryParse('/a/0102030405060708/$maxSeq')!.seq,
        maxSeq,
      );
    });
  });

  group('ObjectAddress', () {
    final hash = contentHash(Uint8List.fromList([9, 9, 9]));

    test('names an object by its own content hash', () {
      final address = ObjectAddress(hash);
      expect(address.path, '/o/${hexEncode(hash)}');
      expect(ObjectAddress.tryParse(address.path), address);
    });

    test('equality is by value', () {
      expect(ObjectAddress(hash), ObjectAddress(Uint8List.fromList(hash)));
      expect(
        ObjectAddress(hash).hashCode,
        ObjectAddress(Uint8List.fromList(hash)).hashCode,
      );
    });

    test('refuses a hash of the wrong width', () {
      expect(() => ObjectAddress(Uint8List(31)), throwsArgumentError);
    });

    test('rejects a malformed path', () {
      for (final path in [
        '',
        '/o',
        '/o/abc',
        '/a/${hexEncode(hash)}',
        '/o/${hexEncode(hash)}/extra',
        '/o/${'z' * 64}',
      ]) {
        expect(
          ObjectAddress.tryParse(path),
          isNull,
          reason: 'must refuse $path',
        );
      }
    });
  });

  test('the cache directive is the one immutability permits', () {
    // Sound only because these paths never change content. This is what
    // separates read volume from relay cost.
    expect(immutableCacheControl, contains('immutable'));
    expect(immutableCacheControl, contains('max-age=31536000'));
    expect(immutableCacheControl, contains('public'));
  });
}
