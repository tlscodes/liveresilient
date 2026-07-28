/// A relay reached over plain HTTPS.
///
/// The transport is injected rather than imported, for the same reason the
/// rest of this package injects its crypto: the package stays pure Dart
/// and testable, and the host app decides what actually opens sockets.
/// The surface is deliberately two methods — this protocol needs a GET and
/// a PUT and nothing else.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'broadcast_address.dart';
import 'broadcast_ids.dart';
import 'broadcast_relay.dart';
import 'publishing_key_certificate.dart';

/// One HTTP response, reduced to what this protocol reads.
class BroadcastHttpResponse {
  const BroadcastHttpResponse({required this.statusCode, this.body});

  final int statusCode;

  /// Present on a 200; absent for every status that carries no bytes.
  final Uint8List? body;
}

/// The HTTP surface a relay client needs.
abstract interface class BroadcastHttpTransport {
  /// GET [url]. Must not throw for an ordinary HTTP error status — return
  /// the status. Throwing is reserved for a transport that failed, which
  /// the caller treats as "this relay is down".
  Future<BroadcastHttpResponse> get(Uri url);

  /// PUT [body] to [url], sending [headers].
  Future<BroadcastHttpResponse> put(
    Uri url,
    Uint8List body, {
    Map<String, String> headers = const {},
  });
}

/// Header a relay reads to check that a descriptor write is the author's.
const String broadcastAuthHeader = 'x-broadcast-auth';

/// What a publisher shows a relay to prove a descriptor is its own.
///
/// The relay holds no keys and knows no authors, so the proof has to be
/// self-contained: the root key names the address, the certificate is
/// signed by that root, and the descriptor is signed by the key the
/// certificate delegates to. Every link is checkable from these bytes
/// alone.
///
/// Without it, write-once protected nobody: anyone could put a byte at an
/// author's coming sequence numbers and hold them for the whole retention
/// window.
class BroadcastCredentials {
  BroadcastCredentials({
    required this.rootPublicKey,
    required this.certificate,
  }) {
    if (rootPublicKey.length != 32) {
      throw ArgumentError.value(
        rootPublicKey.length,
        'rootPublicKey.length',
        'an Ed25519 public key is 32 bytes',
      );
    }
    if (certificate.length != certificateBytes) {
      throw ArgumentError.value(
        certificate.length,
        'certificate.length',
        'a publishing certificate is $certificateBytes bytes',
      );
    }
  }

  /// Build credentials from a publisher's own material.
  factory BroadcastCredentials.of(
    Uint8List rootPublicKey,
    PublishingKeyCertificate certificate,
  ) => BroadcastCredentials(
    rootPublicKey: rootPublicKey,
    certificate: certificate.encoded,
  );

  final Uint8List rootPublicKey;
  final Uint8List certificate;

  /// The header value: base64url of the key followed by the certificate.
  String get headerValue =>
      base64Url.encode([...rootPublicKey, ...certificate]).replaceAll('=', '');

  Map<String, String> get headers => {broadcastAuthHeader: headerValue};
}

/// Why a publish attempt did not store anything.
enum BroadcastPublishFailure {
  /// The address already holds different bytes. On a descriptor path this
  /// is the relay refusing to let history be replaced, which usually means
  /// the sequence number was already used.
  conflict,

  /// Larger than the relay accepts. For media, chunk smaller.
  tooLarge,

  /// The author's rate limit for the current window is used up.
  rateLimited,

  /// The relay has no room.
  outOfSpace,

  /// The relay refused for a reason this client does not model, or the
  /// transport failed outright.
  refused,
}

/// Thrown by [HttpBroadcastRelay.putObject] and `putDescriptor` when the
/// relay declines to store something.
///
/// A publish failure is not an ordinary outcome the way a missing read is:
/// the caller asked for a specific effect and did not get it, and silently
/// continuing would leave a post whose layers are not all there.
class BroadcastPublishRejected implements Exception {
  const BroadcastPublishRejected(this.failure, this.statusCode, this.url);

  final BroadcastPublishFailure failure;
  final int statusCode;
  final Uri url;

  @override
  String toString() =>
      'BroadcastPublishRejected(${failure.name}, HTTP $statusCode, $url)';
}

/// A relay served over HTTPS from one origin.
class HttpBroadcastRelay implements BroadcastRelay {
  HttpBroadcastRelay({
    required this.origin,
    required BroadcastHttpTransport transport,
    this.credentials,
    String? name,
  }) : _transport = transport,
       name = name ?? origin.host {
    if (!origin.isScheme('https') && !origin.isScheme('http')) {
      throw ArgumentError.value(origin, 'origin', 'must be http or https');
    }
  }

  /// Scheme and authority of the relay, for example
  /// `https://relay.example`. Any path on it is ignored.
  final Uri origin;

  /// Proof for descriptor writes. A read-only reader needs none.
  final BroadcastCredentials? credentials;

  final BroadcastHttpTransport _transport;

  @override
  final String name;

  /// Builds an address on [origin], keeping only its scheme, host and port.
  ///
  /// Constructed rather than derived with `replace`, because passing null
  /// to `Uri.replace` means "leave unchanged", so a query string on the
  /// configured origin would survive onto every request and make each
  /// address a second spelling of itself.
  Uri _url(String path) => Uri(
    scheme: origin.scheme,
    host: origin.host,
    port: origin.hasPort ? origin.port : null,
    path: path,
  );

  @override
  Future<Uint8List?> fetchDescriptor(DescriptorAddress address) =>
      _fetch(_url(address.path));

  @override
  Future<Uint8List?> fetchObject(ObjectAddress address) =>
      _fetch(_url(address.path));

  /// Reads one immutable address.
  ///
  /// Anything other than a 200 with a body reads as absent. That includes
  /// a 404 for "not published yet" and every server error: a reader that
  /// has more than one relay should move on rather than distinguish, and
  /// the bytes are verified by the caller regardless of who answered.
  Future<Uint8List?> _fetch(Uri url) async {
    final response = await _transport.get(url);
    if (response.statusCode != 200) return null;
    final body = response.body;
    if (body == null || body.isEmpty) return null;
    return body;
  }

  @override
  Future<void> putDescriptor(DescriptorAddress address, Uint8List encoded) =>
      // Only a descriptor write needs proving. An object is filed under
      // the hash of its own bytes, so its name already says everything a
      // relay could check about it.
      _put(
        _url(address.path),
        encoded,
        headers: credentials?.headers ?? const {},
      );

  @override
  Future<void> putObject(Uint8List bytes) =>
      _put(_url(ObjectAddress(contentHash(bytes)).path), bytes);

  Future<void> _put(
    Uri url,
    Uint8List bytes, {
    Map<String, String> headers = const {},
  }) async {
    final BroadcastHttpResponse response;
    try {
      response = await _transport.put(url, bytes, headers: headers);
    } on Object {
      throw BroadcastPublishRejected(BroadcastPublishFailure.refused, 0, url);
    }
    // 201 stored, 204 already held these exact bytes. Both mean the
    // address now holds what the caller intended, which is the only thing
    // a publisher needs to know.
    if (response.statusCode == 201 || response.statusCode == 204) return;
    throw BroadcastPublishRejected(
      _failureFor(response.statusCode),
      response.statusCode,
      url,
    );
  }

  static BroadcastPublishFailure _failureFor(int status) => switch (status) {
    409 => BroadcastPublishFailure.conflict,
    413 => BroadcastPublishFailure.tooLarge,
    429 => BroadcastPublishFailure.rateLimited,
    507 => BroadcastPublishFailure.outOfSpace,
    _ => BroadcastPublishFailure.refused,
  };
}
