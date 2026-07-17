/// `dart:io` HTTPS implementation of the [ManifestFetcher] contract.
///
/// Security posture:
/// - https-only: a non-https URI throws [ArgumentError] before any I/O;
/// - redirects are followed manually (bounded) and ONLY to https targets;
/// - strict TLS: there is deliberately no `badCertificateCallback` hook.
///   Tests inject a [SecurityContext] that trusts a self-signed dev CA
///   explicitly — hostname/SNI verification stays active either way;
/// - bounded response size: a manifest is small, so an oversized body (or
///   an oversized Content-Length) is treated as a fetch failure;
/// - bounded time: connect and body-read are each capped by [timeout].
///
/// Concurrency: each [fetch] call creates and closes its own [HttpClient]
/// (try/finally, force-closed), so a single [IoManifestFetcher] instance is
/// safe to call concurrently.
library;

import 'dart:async';
import 'dart:io';

import 'manifest_cache.dart' show ManifestFetcher;

/// Network-level manifest fetch failure (HTTP status, size cap, redirect
/// policy, timeout). TLS/socket errors surface as their own exceptions.
class ManifestFetchException implements Exception {
  final Uri uri;
  final String message;

  const ManifestFetchException(this.uri, this.message);

  @override
  String toString() => 'ManifestFetchException($uri): $message';
}

/// HTTPS manifest fetcher backed by `dart:io` [HttpClient].
class IoManifestFetcher {
  /// Cap on both connection establishment and response download.
  final Duration timeout;

  /// Maximum accepted response body size in bytes.
  final int maxBodyBytes;

  /// Maximum https-to-https redirects followed before giving up.
  final int maxRedirects;

  final SecurityContext? _securityContext;

  /// Optional resolver for an on-device forward proxy. When provided, its
  /// return value is used as the HttpClient `findProxy` policy (standard
  /// `dart:io` proxy support, e.g. "PROXY 127.0.0.1:1080" or "DIRECT").
  /// Null (default) means the fetcher connects directly. The core neither
  /// knows nor cares what runs behind the proxy — that lives in an external,
  /// independently audited plugin, wired in only through this neutral hook.
  final String Function(Uri uri)? _proxyResolver;

  IoManifestFetcher({
    this.timeout = const Duration(seconds: 10),
    this.maxBodyBytes = 256 * 1024,
    this.maxRedirects = 5,

    /// Optional trust root override for tests (self-signed localhost dev
    /// certificate). Never disables hostname verification.
    SecurityContext? securityContext,

    /// Optional on-device forward-proxy policy (see [_proxyResolver]).
    String Function(Uri uri)? proxyResolver,
  })  : _securityContext = securityContext,
        _proxyResolver = proxyResolver {
    if (timeout <= Duration.zero) {
      throw ArgumentError.value(timeout, 'timeout', 'Must be positive.');
    }
    if (maxBodyBytes <= 0) {
      throw ArgumentError.value(
        maxBodyBytes,
        'maxBodyBytes',
        'Must be positive.',
      );
    }
    if (maxRedirects < 0) {
      throw ArgumentError.value(maxRedirects, 'maxRedirects', 'Must be >= 0.');
    }
  }

  /// Tear-off matching the [ManifestFetcher] typedef.
  ManifestFetcher get asFetcher => fetch;

  /// Downloads the signed manifest document bytes from [uri].
  Future<List<int>> fetch(Uri uri) async {
    _requireHttps(uri, what: 'Manifest URI');

    final client = HttpClient(context: _securityContext)
      ..connectionTimeout = timeout;
    if (_proxyResolver != null) {
      client.findProxy = _proxyResolver;
    }
    try {
      var target = uri;
      for (var hop = 0; ; hop++) {
        final request = await client.getUrl(target).timeout(timeout);
        request.followRedirects = false;
        final response = await request.close().timeout(timeout);

        if (response.isRedirect) {
          await response.drain<void>();
          if (hop >= maxRedirects) {
            throw ManifestFetchException(uri, 'Too many redirects.');
          }
          final location = response.headers.value(HttpHeaders.locationHeader);
          if (location == null) {
            throw ManifestFetchException(
              uri,
              'Redirect (${response.statusCode}) without a Location header.',
            );
          }
          final next = target.resolve(location);
          _requireHttps(next, what: 'Redirect target', asFetchFailure: uri);
          target = next;
          continue;
        }

        if (response.statusCode != HttpStatus.ok) {
          await response.drain<void>();
          throw ManifestFetchException(
            uri,
            'Unexpected HTTP status ${response.statusCode} from $target.',
          );
        }
        if (response.contentLength > maxBodyBytes) {
          await response.drain<void>();
          throw ManifestFetchException(
            uri,
            'Declared Content-Length ${response.contentLength} exceeds the '
            '$maxBodyBytes-byte manifest cap.',
          );
        }
        return await _readCapped(uri, response);
      }
    } finally {
      client.close(force: true);
    }
  }

  Future<List<int>> _readCapped(Uri uri, HttpClientResponse response) async {
    final bytes = <int>[];
    await response
        .forEach((chunk) {
          if (bytes.length + chunk.length > maxBodyBytes) {
            throw ManifestFetchException(
              uri,
              'Response body exceeds the $maxBodyBytes-byte manifest cap.',
            );
          }
          bytes.addAll(chunk);
        })
        .timeout(timeout);
    return bytes;
  }

  void _requireHttps(Uri uri, {required String what, Uri? asFetchFailure}) {
    if (uri.scheme == 'https' && uri.host.isNotEmpty) return;
    if (asFetchFailure != null) {
      // A server steering us off https mid-flight is a fetch failure, not a
      // caller programming error.
      throw ManifestFetchException(
        asFetchFailure,
        '$what must be https, got: $uri',
      );
    }
    throw ArgumentError.value(uri, 'uri', '$what must be https.');
  }
}
