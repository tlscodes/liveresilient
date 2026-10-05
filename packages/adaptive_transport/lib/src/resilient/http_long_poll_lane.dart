import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../transport_channel.dart';

/// Last-resort standard-web fallback: frames sent as HTTPS POST bodies to
/// our own backend endpoint over a plain [HttpClient]. Traverses the most
/// restrictive corporate egress policies, which typically permit outbound
/// HTTPS on port 443 even when everything else (raw UDP, WS upgrades) is
/// blocked. Highest latency and lowest reliability prior of the chain.
class HttpLongPollLane implements TransportChannel {
  HttpLongPollLane({
    required Uri sendUri,
    Uri? healthCheckUri,
    Duration requestTimeout = const Duration(seconds: 5),
    HttpClient? client,
  }) : _sendUri = sendUri,
       _healthCheckUri = healthCheckUri ?? sendUri,
       _requestTimeout = requestTimeout,
       _client = client ?? HttpClient(),
       health = ChannelHealth(reliabilityPrior: 0.6, bandwidth: 0.3);

  final Uri _sendUri;
  final Uri _healthCheckUri;
  final Duration _requestTimeout;
  final HttpClient _client;

  @override
  final ChannelHealth health;

  @override
  String get name => 'http-long-poll';

  @override
  Future<bool> probe() async {
    final started = DateTime.now();
    try {
      final request = await _client
          .headUrl(_healthCheckUri)
          .timeout(_requestTimeout);
      final response = await request.close().timeout(_requestTimeout);
      await response.drain<void>();
      final rtt = DateTime.now().difference(started).inMilliseconds;
      final ok = response.statusCode >= 200 && response.statusCode < 300;
      health.observe(
        SendResult(ok ? SendStatus.ok : SendStatus.unavailable, rttMs: rtt),
      );
      return ok;
    } catch (error) {
      health.observe(SendResult(SendStatus.unavailable, error: error));
      return false;
    }
  }

  @override
  Future<SendResult> send(List<int> payload) async {
    final started = DateTime.now();
    try {
      final request = await _client.postUrl(_sendUri).timeout(_requestTimeout);
      request.headers.contentType = ContentType.binary;
      request.add(payload);
      final response = await request.close().timeout(_requestTimeout);
      await response.drain<void>();
      final rtt = DateTime.now().difference(started).inMilliseconds;

      if (response.statusCode >= 200 && response.statusCode < 300) {
        final result = SendResult(SendStatus.ok, rttMs: rtt);
        health.observe(result);
        return result;
      }
      if (response.statusCode >= 500) {
        final result = SendResult(SendStatus.transient, rttMs: rtt);
        health.observe(result);
        return result;
      }
      final result = SendResult(SendStatus.unavailable, rttMs: rtt);
      health.observe(result);
      return result;
    } catch (error) {
      final result = SendResult(SendStatus.unavailable, error: error);
      health.observe(result);
      return result;
    }
  }

  /// The receiving half of this lane: asks the endpoint for whatever it is
  /// holding for this side, waiting up to [wait] for the first frame.
  ///
  /// The relay has always answered `GET` on the same URL the lane posts to
  /// (see the border relay's long-poll route); nothing on the client ever
  /// asked. Returns the bytes exactly as held — frames are concatenated, so
  /// the caller's frames must delimit themselves — an empty list when
  /// nothing is waiting, and null when the endpoint could not be reached.
  Future<Uint8List?> receive({Duration wait = Duration.zero}) async {
    final started = DateTime.now();
    final budget = _requestTimeout + wait;
    try {
      final uri = _sendUri.replace(
        queryParameters: <String, String>{
          ..._sendUri.queryParameters,
          'wait': '${wait.inMilliseconds}',
        },
      );
      final request = await _client.getUrl(uri).timeout(_requestTimeout);
      final response = await request.close().timeout(budget);
      final body = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(budget)) {
        body.add(chunk);
      }
      final rtt = DateTime.now().difference(started).inMilliseconds;
      if (response.statusCode >= 200 && response.statusCode < 300) {
        // A long-poll's round trip is mostly the wait it asked for, so it
        // says the endpoint is alive without being a latency sample.
        health.observe(
          SendResult(SendStatus.ok, rttMs: wait > Duration.zero ? null : rtt),
        );
        return body.takeBytes();
      }
      health.observe(
        SendResult(
          response.statusCode >= 500
              ? SendStatus.transient
              : SendStatus.unavailable,
          rttMs: rtt,
        ),
      );
      return null;
    } catch (error) {
      health.observe(SendResult(SendStatus.unavailable, error: error));
      return null;
    }
  }

  @override
  Future<void> dispose() async {
    _client.close(force: true);
  }
}
