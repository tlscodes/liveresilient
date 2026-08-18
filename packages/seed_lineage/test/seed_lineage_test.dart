/// The cross-language vector is the point of this test file.
///
/// The same values are asserted by the engine's Rust test
/// `genealogy_matches_the_cross_language_vector`. Both were taken from a THIRD
/// implementation (Python's hashlib BLAKE2b), so a bug shared between the Rust
/// and Dart code cannot make both sides agree wrongly.
library;

import 'dart:typed_data';

import 'package:seed_lineage/seed_lineage.dart';
import 'package:test/test.dart';

/// A fixed manifest hash of 00 01 02 ... 1f. Fixed rather than computed so the
/// vector does not depend on either project's manifest contents.
final Uint8List fixedManifestHash = Uint8List.fromList(
  List<int>.generate(32, (i) => i),
);

const int rootSeed = 1337;

const String expectedDomainSeed =
    '43a517ee9daa904f8d962fd57b561cae0564999ad96f97ca3eebdd3b38794327';
const String expectedStreamSeed =
    '01124db64adfc054f6dfc02fe488ec835d016b8e780731f040f355cb2d85f226';

void main() {
  test('domain seed matches the cross-language vector', () {
    final d = domainSeed(
      rootSeed: rootSeed,
      manifestHash: fixedManifestHash,
      domain: 'jitter',
    );
    expect(toHex(d), expectedDomainSeed);
  });

  test('stream seed matches the cross-language vector', () {
    final d = domainSeed(
      rootSeed: rootSeed,
      manifestHash: fixedManifestHash,
      domain: 'jitter',
    );
    expect(
      toHex(streamSeed(domainSeed: d, logicalPath: 'chan/0')),
      expectedStreamSeed,
    );
  });

  test('distinct logical paths diverge', () {
    final d = domainSeed(
      rootSeed: rootSeed,
      manifestHash: fixedManifestHash,
      domain: 'jitter',
    );
    expect(
      toHex(streamSeed(domainSeed: d, logicalPath: 'chan/0')),
      isNot(toHex(streamSeed(domainSeed: d, logicalPath: 'chan/1'))),
    );
  });

  test('a different manifest hash reseeds every domain', () {
    final other = Uint8List.fromList(List<int>.generate(32, (i) => i + 1));
    expect(
      toHex(
        domainSeed(
          rootSeed: rootSeed,
          manifestHash: fixedManifestHash,
          domain: 'jitter',
        ),
      ),
      isNot(
        toHex(
          domainSeed(rootSeed: rootSeed, manifestHash: other, domain: 'jitter'),
        ),
      ),
    );
  });

  test('a wrong-length manifest hash is rejected, not padded', () {
    expect(
      () => domainSeed(
        rootSeed: rootSeed,
        manifestHash: Uint8List(16),
        domain: 'jitter',
      ),
      throwsArgumentError,
    );
  });

  test('root seed encodes little-endian like Rust u64::to_le_bytes', () {
    expect(
      toHex(rootSeedBytes(1)),
      '0100000000000000',
      reason: 'least significant byte first',
    );
    expect(toHex(rootSeedBytes(0x0102030405060708)), '0807060504030201');
  });

  test('hex round-trips', () {
    final d = domainSeed(
      rootSeed: rootSeed,
      manifestHash: fixedManifestHash,
      domain: 'jitter',
    );
    expect(fromHex(toHex(d)), d);
  });

  test('the Random seed takes the low 32 bits, explicitly', () {
    final seed = Uint8List.fromList([
      0x78,
      0x56,
      0x34,
      0x12,
      ...List<int>.filled(28, 0xFF),
    ]);
    expect(toRandomSeed(seed), 0x12345678);
  });
}
