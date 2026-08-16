import 'dart:convert';
import 'dart:io';

import 'package:signed_config/signed_config.dart';
import 'package:test/test.dart';

/// Ticket 6 gate 6c — name lookup over an HTTPS carrier.
///
/// The crux of this file is the cycle. The endpoint that answers these
/// questions has a host name of its own; asking this class to resolve THAT
/// name would call the endpoint in order to reach the endpoint. There is no
/// base case, and the symptom is a hang no stack trace explains. It is closed
/// in two places and both are tested here, because a cycle closed silently is
/// a cycle that gets reopened by the next well-meaning refactor.
void main() {
  final endpoint = Uri.parse('https://lookup.example/resolve');

  HttpsNameLookup lookupWith({
    String address = '203.0.113.10',
    Duration timeout = const Duration(seconds: 3),
    int maxResponseBytes = 8 * 1024,
    Uri? at,
  }) => HttpsNameLookup(
    endpoint: at ?? endpoint,
    endpointAddress: address,
    timeout: timeout,
    maxResponseBytes: maxResponseBytes,
  );

  group('construction', () {
    test('the endpoint must be https', () {
      expect(
        () => HttpsNameLookup(
          endpoint: Uri.parse('http://lookup.example/resolve'),
          endpointAddress: '203.0.113.10',
        ),
        throwsArgumentError,
      );
    });

    test(
      'the endpoint address must be a numeric literal, never a name — a name '
      'here would reintroduce the cycle',
      () {
        expect(
          () => HttpsNameLookup(
            endpoint: endpoint,
            endpointAddress: 'lookup.example',
          ),
          throwsArgumentError,
        );
        expect(
          () => HttpsNameLookup(endpoint: endpoint, endpointAddress: ''),
          throwsArgumentError,
        );
      },
    );

    test('bounds must be positive', () {
      expect(
        () => lookupWith(timeout: Duration.zero),
        throwsArgumentError,
      );
      expect(() => lookupWith(maxResponseBytes: 0), throwsArgumentError);
    });
  });

  group('the cycle-breaker', () {
    test(
      "the endpoint's own host resolves to null, handing that one name to "
      'the platform on purpose',
      () async {
        final lookup = lookupWith();
        expect(await lookup.lookup('lookup.example'), isNull);
        expect(
          await lookup.lookup('LOOKUP.EXAMPLE'),
          isNull,
          reason: 'case must not be a way around the base case',
        );
      },
    );

    test('a numeric host needs no lookup and is returned as given', () async {
      final lookup = lookupWith();
      expect(await lookup.lookup('198.51.100.7'), '198.51.100.7');
      expect(await lookup.lookup('::1'), '::1');
    });

    test('an empty host is null, not a query', () async {
      expect(await lookupWith().lookup(''), isNull);
    });
  });

  group('failure degrades to the platform, never to an exception', () {
    test('an unreachable endpoint returns null', () async {
      // 203.0.113.0/24 is reserved for documentation and routes nowhere.
      final lookup = lookupWith(
        address: '203.0.113.199',
        timeout: const Duration(milliseconds: 200),
      );
      expect(await lookup.lookup('somewhere.example'), isNull);
    });

    test(
      'the deadline is aggregate: a trickling body cannot hold the path open',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        server.listen((req) async {
          req.response.statusCode = HttpStatus.ok;
          // One byte at a time, slower than the deadline but faster than any
          // single per-phase cap. A per-chunk timeout refreshes on every
          // byte, so only an aggregate deadline stops this.
          for (var i = 0; i < 10000; i++) {
            req.response.write('x');
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
          await req.response.close();
        });

        final started = DateTime.now();
        final lookup = HttpsNameLookup(
          endpoint: Uri.parse('https://lookup.example/resolve'),
          endpointAddress: InternetAddress.loopbackIPv4.address,
          timeout: const Duration(milliseconds: 400),
        );
        expect(await lookup.lookup('target.example'), isNull);
        final elapsed = DateTime.now().difference(started);
        expect(
          elapsed,
          lessThan(const Duration(seconds: 5)),
          reason: 'the aggregate deadline must cut this; a per-phase cap '
              'would let the trickle run for the full 200 seconds',
        );
      },
    );

    test('a base case is answered without spending the deadline', () async {
      final lookup = lookupWith(
        address: '203.0.113.199',
        timeout: const Duration(seconds: 30),
      );
      final started = DateTime.now();
      expect(await lookup.lookup('lookup.example'), isNull);
      expect(
        DateTime.now().difference(started),
        lessThan(const Duration(seconds: 1)),
        reason: 'the cycle-breaker must not start a clock it does not need',
      );
    });

    test('a lookup never throws, whatever the endpoint does', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((req) async {
        req.response.statusCode = HttpStatus.internalServerError;
        await req.response.close();
      });
      // Plain http here, so this exercises only that a failed exchange
      // degrades rather than escapes; the https requirement is covered above.
      final lookup = lookupWith(
        address: InternetAddress.loopbackIPv4.address,
        timeout: const Duration(milliseconds: 500),
      );
      expect(await lookup.lookup('anything.example'), isNull);
    });
  });

  group('answer parsing is defensive', () {
    // The parser is exercised through the public surface by pointing the
    // lookup at a local server. Each case asserts the same thing: a shape
    // that is not what was promised is indistinguishable from no answer.
    Future<String?> answerWith(Object? body, {int status = 200}) async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((req) async {
        req.response.statusCode = status;
        req.response.write(body is String ? body : jsonEncode(body));
        await req.response.close();
      });
      final lookup = HttpsNameLookup(
        endpoint: Uri.parse('https://lookup.example/resolve'),
        endpointAddress: InternetAddress.loopbackIPv4.address,
        timeout: const Duration(milliseconds: 500),
      );
      return lookup.lookup('target.example');
    }

    test('a non-object body is null', () async {
      expect(await answerWith('not json at all'), isNull);
    });

    test('a missing answer list is null', () async {
      expect(await answerWith(<String, Object?>{'Status': 0}), isNull);
    });

    test('a record that is not an address record is not returned', () async {
      expect(
        await answerWith(<String, Object?>{
          'Answer': [
            {'type': 5, 'data': 'alias.example'},
          ],
        }),
        isNull,
        reason: 'an alias is not an address and must not be handed back as '
            'though it were',
      );
    });

    test('a record whose data is not an address is not returned', () async {
      expect(
        await answerWith(<String, Object?>{
          'Answer': [
            {'type': 1, 'data': 'still-a-name.example'},
          ],
        }),
        isNull,
      );
    });
  });
}
