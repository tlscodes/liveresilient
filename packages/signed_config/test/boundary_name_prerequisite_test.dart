/// Ticket 6 gate 6f — is every hostname known at the boundary?
///
/// THE QUESTION, AND WHY IT DECIDES A TOPOLOGY. Ticket 6's design assumed the
/// caller knows every name before work starts, because that assumption is what
/// permits the cheap shape: resolve the whole set once at the boundary and hand
/// addresses downward. If names can appear DURING an operation, that shape is
/// invalid — the seam has to stay live per attempt, and a design that resolves
/// once at the top would silently miss whatever appeared later.
///
/// WHY THIS IS A TEST AND NOT A QUOTATION. The answer was already recorded in
/// the plan by reading three code sites. A recorded reading is a claim about
/// yesterday's code: it stays in the document after a refactor moves the lines,
/// and nothing detects that it has stopped being true. So this file re-derives
/// the answer from BEHAVIOUR — a real TLS server, the production fetcher, and a
/// recording seam — and it will fail if the answer ever changes. If a future
/// refactor makes all names known at the boundary, these tests go red and the
/// topology decision gets revisited deliberately, which is exactly the service
/// the recorded note could not provide.
///
/// THE ANSWER IT REPRODUCES: no. A server-supplied redirect introduces a
/// hostname the caller never had, so the number of names is bounded (by
/// maxRedirects) but not knowable in advance.
library;

import 'dart:io';

import 'package:signed_config/signed_config.dart';
import 'package:test/test.dart';

import 'support/localhost_tls.dart';

void main() {
  late Directory tempDir;
  late SecurityContext serverContext;
  late SecurityContext clientContext;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('signed_config_6f_');
    final cert = await generateLocalhostCert(tempDir);
    serverContext = SecurityContext()
      ..useCertificateChain(cert.chainPath)
      ..usePrivateKey(cert.leafKeyPath);
    // A real trust anchor: hostname verification stays ACTIVE for every name
    // below, so a redirect to a second name is a genuine verified connection
    // and not an artefact of a disabled check.
    clientContext = SecurityContext(withTrustedRoots: false)
      ..setTrustedCertificates(cert.caCertPath);
  });

  tearDownAll(() async {
    await tempDir.delete(recursive: true);
  });

  group('gate 6f — are all names known at the boundary?', () {
    test(
      '6f  a redirect introduces a hostname the caller never supplied',
      () async {
        final origin = await TestOrigin.start(serverContext);
        final destination = await TestOrigin.start(serverContext);
        addTearDown(() async {
          await origin.stop();
          await destination.stop();
        });
        destination.body = <int>[123, 125]; // `{}`; the body is not the subject

        // The caller asks for ONE name. The certificate covers both `localhost`
        // and `127.0.0.1`, so the second hop verifies normally — the only thing
        // that differs between the two hops is the name itself.
        final asked = <String>[];
        final fetcher = IoManifestFetcher(
          securityContext: clientContext,
          resolveAddress: (host) async {
            asked.add(host);
            return null; // record only; let the platform resolve as usual
          },
        );
        origin.redirectTo = destination.manifestUri.toString();

        await fetcher.fetch(origin.manifestUriByName);

        expect(
          asked.first,
          'localhost',
          reason: 'the boundary name is the one the caller supplied',
        );
        final unforeseen = asked
            .skip(1)
            .where((h) => h != asked.first)
            .toList();
        expect(
          unforeseen,
          isNotEmpty,
          reason:
              'this is the whole gate: a name arrived that the caller could '
              'not have resolved in advance, because the server chose it. '
              'Names asked, in order: $asked',
        );
        expect(
          unforeseen,
          contains('127.0.0.1'),
          reason: 'and it is the name the redirect named, not an artefact',
        );
      },
    );

    test('6f  the seam is consulted per attempt, not once per call', () async {
      // The consequence for the design: since the second name only exists
      // after the first response, the seam cannot be a boundary-time
      // pre-resolution step. It has to be reachable on every attempt.
      final origin = await TestOrigin.start(serverContext);
      final destination = await TestOrigin.start(serverContext);
      addTearDown(() async {
        await origin.stop();
        await destination.stop();
      });
      destination.body = <int>[123, 125];

      var consultations = 0;
      final fetcher = IoManifestFetcher(
        securityContext: clientContext,
        resolveAddress: (host) async {
          consultations++;
          return null;
        },
      );
      origin.redirectTo = destination.manifestUri.toString();

      await fetcher.fetch(origin.manifestUriByName);

      expect(
        consultations,
        greaterThan(1),
        reason: 'one fetch, more than one connection, so more than one name',
      );
    });

    test(
      '6f  the count of names is bounded but not known in advance',
      () async {
        // Bounded matters as much as unknown: an unbounded chain would be a
        // different defect (a redirect loop), and the fetcher refuses one. So
        // the honest statement is "at most maxRedirects + 1 names, and which
        // ones is up to the server" — which is still incompatible with
        // resolving the set at the boundary.
        final hop1 = await TestOrigin.start(serverContext);
        final hop2 = await TestOrigin.start(serverContext);
        final hop3 = await TestOrigin.start(serverContext);
        addTearDown(() async {
          await hop1.stop();
          await hop2.stop();
          await hop3.stop();
        });
        hop3.body = <int>[123, 125];

        final asked = <String>[];
        final fetcher = IoManifestFetcher(
          securityContext: clientContext,
          maxRedirects: 5,
          resolveAddress: (host) async {
            asked.add(host);
            return null;
          },
        );
        // Alternate the NAME each hop, so each hop's name is chosen by the
        // previous server rather than by the caller.
        hop1.redirectTo = hop2.manifestUri.toString();
        hop2.redirectTo = hop3.manifestUriByName.toString();

        await fetcher.fetch(hop1.manifestUriByName);

        expect(asked.length, 3, reason: 'three connections: $asked');
        expect(
          asked,
          ['localhost', '127.0.0.1', 'localhost'],
          reason:
              'the sequence of names is authored by the servers, one hop at '
              'a time',
        );

        // And the bound is real: a chain longer than maxRedirects is refused
        // rather than followed forever.
        final loop = await TestOrigin.start(serverContext);
        addTearDown(() => loop.stop());
        loop.redirectTo = loop.manifestUri.toString();
        final bounded = IoManifestFetcher(
          securityContext: clientContext,
          maxRedirects: 2,
          resolveAddress: (host) async => null,
        );
        await expectLater(
          bounded.fetch(loop.manifestUriByName),
          throwsA(isA<ManifestFetchException>()),
        );
      },
    );
  });
}
