/// Shared test doubles for the signed_config test suite.
///
/// No real cryptography exists in this package (by design — see
/// `manifest_verifier.dart` doc comment): the app plugs in an audited
/// `Ed25519Verifier` implementation. These tests exercise verifier ORDER and
/// cache LOGIC, not crypto, so [FakeEd25519Verifier] implements a
/// deterministic, non-cryptographic "signature" scheme: a valid signature is
/// exactly the 32 pinned-key bytes followed by a 32-byte rolling checksum of
/// the signed message. Any byte difference (wrong key, tampered message,
/// tampered signature) fails verification, which is all the tests need.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:signed_config/signed_config.dart';

/// A mutable fake clock so tests never wait on real time.
class FakeClock {
  DateTime _now;
  FakeClock(this._now);

  DateTime call() => _now;

  void set(DateTime now) => _now = now;
  void advance(Duration by) => _now = _now.add(by);
}

/// Deterministic non-cryptographic "signature": 32 bytes of [publicKey] +
/// a 32-byte rolling checksum of [message]. Same publicKey+message always
/// produces the same 64-byte output; any tamper to either changes it.
Uint8List fakeSign({required Uint8List publicKey, required Uint8List message}) {
  final checksum = Uint8List(32);
  for (var i = 0; i < message.length; i++) {
    checksum[i % 32] = (checksum[i % 32] + message[i] + i) & 0xff;
  }
  return Uint8List.fromList([...publicKey, ...checksum]);
}

bool bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Fake [Ed25519Verifier]. Valid iff `signature == fakeSign(publicKey,
/// message)`, unless [forceInvalid] is set (simulates a corrupted
/// signature independent of byte content).
class FakeEd25519Verifier implements Ed25519Verifier {
  bool forceInvalid = false;
  int callCount = 0;

  @override
  Future<bool> verify({
    required Uint8List message,
    required Uint8List signature,
    required Uint8List publicKey,
  }) async {
    callCount++;
    if (forceInvalid) return false;
    return bytesEqual(
      signature,
      fakeSign(publicKey: publicKey, message: message),
    );
  }
}

/// Deterministic 32-byte pinned-key material, distinct per [seed].
Uint8List keyBytes(int seed) =>
    Uint8List.fromList(List.generate(32, (i) => (seed * 7 + i * 3) & 0xff));

/// Builds a valid [EndpointManifest] with sane defaults, overridable per
/// test.
EndpointManifest buildManifest({
  int revision = 1,
  String signingKeyId = 'key-1',
  DateTime? issuedAt,
  DateTime? expiresAt,
  int schemaVersion = manifestSchemaVersion,
}) {
  final issued = issuedAt ?? DateTime.utc(2026, 1, 1);
  final expires = expiresAt ?? issued.add(const Duration(hours: 1));
  return EndpointManifest(
    schemaVersion: schemaVersion,
    revision: revision,
    signingKeyId: signingKeyId,
    issuedAt: issued,
    expiresAt: expires,
    signalingEndpoints: [Uri.parse('wss://signal.example.com/v1')],
    iceServers: const [],
    configServiceUri: Uri.parse('https://config.example.com/manifest'),
  );
}

/// Signs [manifest] against [publicKey] using the fake scheme, optionally
/// overriding the raw signature bytes (for tamper / bad-length tests).
SignedManifestDocument signManifest(
  EndpointManifest manifest,
  Uint8List publicKey, {
  List<int>? signatureOverride,
}) {
  final message = Uint8List.fromList(manifest.canonicalBytes());
  final signature =
      signatureOverride ?? fakeSign(publicKey: publicKey, message: message);
  return SignedManifestDocument(
    manifestJson: manifest.toJson(),
    signature: signature,
  );
}

/// Encodes a [SignedManifestDocument] into the wire transport format
/// consumed by `SignedManifestDocument.fromBytes`.
List<int> encodeSignedDocument(SignedManifestDocument document) => utf8.encode(
  jsonEncode({
    'manifest': document.manifestJson,
    'signature': base64Encode(document.signature),
  }),
);

/// In-memory [ManifestStorage] fake.
class FakeManifestStorage implements ManifestStorage {
  List<int>? document;
  int acceptedRevision = 0;

  @override
  Future<List<int>?> readDocument() async => document;

  @override
  Future<void> writeDocument(List<int> bytes) async {
    document = bytes;
  }

  @override
  Future<int> readAcceptedRevision() async => acceptedRevision;

  @override
  Future<void> writeAcceptedRevision(int revision) async {
    acceptedRevision = revision;
  }
}

/// Controllable [ManifestFetcher] fake: enqueue successes/failures, replayed
/// in order; asserts loudly if a test under-provisions responses.
class FakeFetcher {
  final List<Object> _queue = [];
  int calls = 0;
  Uri? lastUri;

  void enqueueSuccess(List<int> bytes) => _queue.add(bytes);
  void enqueueFailure(Object error) => _queue.add(error);

  Future<List<int>> call(Uri uri) async {
    calls++;
    lastUri = uri;
    if (_queue.isEmpty) {
      throw StateError('FakeFetcher: no queued response for $uri');
    }
    final next = _queue.removeAt(0);
    if (next is List<int>) return next;
    throw next;
  }
}
