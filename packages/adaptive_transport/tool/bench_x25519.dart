import 'dart:typed_data';

import 'package:adaptive_transport/adaptive_transport.dart';

Future<void> main() async {
  final agreement = X25519KeyAgreement();
  final a = await agreement.generateEphemeral();
  final b = await agreement.generateEphemeral();

  // Warm up the JIT.
  for (var i = 0; i < 20; i++) {
    await agreement.sharedSecret(
      privateKey: a.privateKey,
      peerPublicKey: b.publicKey,
    );
  }

  const iterations = 200;
  final sw = Stopwatch()..start();
  for (var i = 0; i < iterations; i++) {
    await agreement.sharedSecret(
      privateKey: a.privateKey,
      peerPublicKey: b.publicKey,
    );
  }
  sw.stop();
  final perOp = sw.elapsedMicroseconds / iterations;
  print('X25519 sharedSecret: ${perOp.toStringAsFixed(1)} us/op');

  final swGen = Stopwatch()..start();
  for (var i = 0; i < 50; i++) {
    await agreement.generateEphemeral();
  }
  swGen.stop();
  print(
    'X25519 keygen:       ${(swGen.elapsedMicroseconds / 50).toStringAsFixed(1)} us/op',
  );

  // Credential derivation (HKDF) for comparison.
  final shared = Uint8List(32);
  final swHkdf = Stopwatch()..start();
  for (var i = 0; i < 1000; i++) {
    RealityCredential.fromSharedSecret(shared);
  }
  swHkdf.stop();
  print(
    'HKDF credential:     ${(swHkdf.elapsedMicroseconds / 1000).toStringAsFixed(1)} us/op',
  );
}
