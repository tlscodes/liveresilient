/// Shared trivial test doubles for the device_link test suite.
///
/// No real cryptography lives here on purpose: [FakeSigner]/[FakeVerifier]
/// are a deterministic, reproducible transform of (keyId, message) so
/// signature *pairing* can be asserted without depending on an audited
/// crypto library. The behaviour under test in this package is replay/nonce/
/// freshness/hop/consent gating, not signature math.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:device_link/device_link.dart';

Uint8List _fakeSignature(String keyId, Uint8List message) {
  final marker = utf8.encode('sig:$keyId:');
  final reversedPayload = message.reversed.toList();
  return Uint8List.fromList([...marker, ...reversedPayload]);
}

bool _bytesEqual(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Deterministic fake signer paired with [FakeVerifier].
class FakeSigner implements EnvelopeSigner {
  @override
  final String keyId;

  FakeSigner(this.keyId);

  @override
  Future<Uint8List> sign(Uint8List message) async =>
      _fakeSignature(keyId, message);
}

/// Deterministic fake verifier: recomputes the expected [FakeSigner] output
/// for the claimed keyId and compares bytes. Unknown key ids always fail,
/// matching the real adapter contract. [forceFail] simulates an
/// always-failing verifier without hand-corrupting envelope bytes.
class FakeVerifier implements EnvelopeVerifier {
  final Set<String> trustedKeyIds;
  bool forceFail = false;

  FakeVerifier(this.trustedKeyIds);

  @override
  Future<bool> verify({
    required String keyId,
    required Uint8List message,
    required Uint8List signature,
  }) async {
    if (forceFail) return false;
    if (!trustedKeyIds.contains(keyId)) return false;
    return _bytesEqual(_fakeSignature(keyId, message), signature);
  }
}

/// Mutable consent fake; flip [granted] mid-test to simulate revocation.
class FakeConsent implements DeviceLinkConsent {
  @override
  bool granted;

  FakeConsent({this.granted = true});
}

/// In-memory [LocalLinkPort]: records every outbound send and lets the test
/// push arbitrary inbound bytes (including malformed ones) on demand.
class FakeLocalLinkPort implements LocalLinkPort {
  final _incoming = StreamController<List<int>>.broadcast();
  final List<List<int>> sentBytes = [];
  bool reachable = true;
  bool throwOnReachable = false;
  bool throwOnSend = false;
  int rttMs = 25;
  bool closed = false;

  @override
  Future<bool> isPeerReachable() async {
    if (throwOnReachable) {
      throw StateError('link unreachable check failed');
    }
    return reachable;
  }

  @override
  Future<int> sendBytes(List<int> bytes) async {
    if (throwOnSend) {
      throw StateError('link send failed');
    }
    sentBytes.add(bytes);
    return rttMs;
  }

  @override
  Stream<List<int>> get incomingFrames => _incoming.stream;

  void pushIncoming(List<int> bytes) => _incoming.add(bytes);

  @override
  Future<void> close() async {
    closed = true;
    await _incoming.close();
  }
}
