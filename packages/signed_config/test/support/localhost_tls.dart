/// Real-TLS loopback scaffolding shared by more than one suite.
///
/// Both pieces were written for `https_loopback_discovery_test.dart` and moved
/// here unchanged when the gate 6f prerequisite check needed the same two
/// things: a certificate a real verifier accepts, and an origin that can be
/// told to redirect. Importing one test file from another works but reads as an
/// accident; a support library says the sharing is deliberate.
library;

import 'dart:io';

/// Generates a localhost server certificate into [dir] with the system
/// `openssl` binary (dev_certificate.dart recipe, extended to a mini
/// CA-signs-leaf chain).
///
/// Unlike the wss tests — which skip verification with
/// `badCertificateCallback` — suites using this install a real TRUST ANCHOR via
/// `setTrustedCertificates`, and the Dart/BoringSSL verifier refuses a
/// self-signed LEAF as an anchor (probed empirically: CERTIFICATE_VERIFY_
/// FAILED even with CA:TRUE on the leaf). A minimal CA that signs a
/// SAN=localhost/127.0.0.1 leaf verifies cleanly, with hostname checking
/// still active.
///
/// The SAN covering BOTH `localhost` and `127.0.0.1` is what lets a test send
/// its first request to one of those names and be redirected to the other with
/// verification still on — which is how a mid-flight hostname is produced
/// without a second certificate.
Future<({String caCertPath, String chainPath, String leafKeyPath})>
generateLocalhostCert(Directory dir) async {
  final p = dir.path;

  Future<void> run(List<String> args) async {
    final result = await Process.run('openssl', args);
    if (result.exitCode != 0) {
      throw StateError(
        'openssl ${args.first} failed (exit ${result.exitCode}): '
        '${result.stderr}',
      );
    }
  }

  // Mini test CA (the client's sole trust anchor).
  await run([
    'req',
    '-x509',
    '-newkey',
    'rsa:2048',
    '-nodes',
    '-keyout',
    '$p/ca-key.pem',
    '-out',
    '$p/ca.pem',
    '-days',
    '30',
    '-subj',
    '/CN=signed_config loopback test CA',
    '-addext',
    'basicConstraints=critical,CA:TRUE',
    '-addext',
    'keyUsage=critical,keyCertSign',
  ]);
  // Leaf key + CSR, then CA-sign with localhost/127.0.0.1 SANs.
  await run([
    'req',
    '-newkey',
    'rsa:2048',
    '-nodes',
    '-keyout',
    '$p/leaf-key.pem',
    '-out',
    '$p/leaf.csr',
    '-subj',
    '/CN=localhost',
  ]);
  final extFile = File('$p/leaf.ext')
    ..writeAsStringSync(
      'subjectAltName=DNS:localhost,IP:127.0.0.1\n'
      'basicConstraints=CA:FALSE\n'
      'keyUsage=digitalSignature,keyEncipherment\n'
      'extendedKeyUsage=serverAuth\n',
    );
  await run([
    'x509',
    '-req',
    '-in',
    '$p/leaf.csr',
    '-CA',
    '$p/ca.pem',
    '-CAkey',
    '$p/ca-key.pem',
    '-CAcreateserial',
    '-days',
    '30',
    '-out',
    '$p/leaf.pem',
    '-extfile',
    extFile.path,
  ]);
  // Server presents leaf + CA chain.
  final chain = File('$p/chain.pem')
    ..writeAsStringSync(
      File('$p/leaf.pem').readAsStringSync() +
          File('$p/ca.pem').readAsStringSync(),
    );

  return (
    caCertPath: '$p/ca.pem',
    chainPath: chain.path,
    leafKeyPath: '$p/leaf-key.pem',
  );
}

/// One scriptable HTTPS manifest origin on an ephemeral loopback port.
class TestOrigin {
  final HttpServer _server;
  int requestCount = 0;

  /// Every path this origin was asked for, in order. Lets a test assert WHICH
  /// request went where, not only how many arrived.
  final List<String> requestedPaths = <String>[];

  /// Body to serve; null -> HTTP 500.
  List<int>? body;

  /// When set, responds 302 to this location instead of a body.
  String? redirectTo;

  /// Declare Content-Length (true) or stream chunked (false).
  bool declareLength = true;

  /// Captured at bind time so the URI stays valid after [stop].
  final int port;

  TestOrigin._(this._server) : port = _server.port {
    _server.listen(_handle);
  }

  static Future<TestOrigin> start(SecurityContext serverContext) async {
    final server = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      serverContext,
    );
    return TestOrigin._(server);
  }

  Uri get manifestUri => Uri.parse('https://127.0.0.1:$port/manifest');

  /// The same origin addressed by NAME rather than by literal address. Both
  /// are in the certificate's SAN, so verification stays active either way.
  Uri get manifestUriByName => Uri.parse('https://localhost:$port/manifest');

  void _handle(HttpRequest request) {
    requestCount++;
    requestedPaths.add(request.uri.path);
    final response = request.response;
    final redirect = redirectTo;
    final bytes = body;
    if (redirect != null) {
      response.statusCode = HttpStatus.found;
      response.headers.set(HttpHeaders.locationHeader, redirect);
    } else if (bytes == null) {
      response.statusCode = HttpStatus.internalServerError;
    } else {
      if (declareLength) response.contentLength = bytes.length;
      response.add(bytes);
    }
    response.close();
  }

  Future<void> stop() => _server.close(force: true);
}
