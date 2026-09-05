/// The phone side of the app journey as a PERSISTENT peer.
///
/// Installed once, launched per profile, never reinstalled — so the
/// microphone prompt is answered once and every profile row carries real
/// audio (a replaced install re-asks, measured 2026-09-03: normal and
/// extreme ran without phone audio for that reason alone). It is a plain
/// Flutter app, not a test: nothing attaches to it, so its evidence travels
/// over the rig's plain-HTTP hub instead of a test log.
///
/// Loop: pre-warm the microphone (the one prompt) → GET /job → build a real
/// call stack (initiator) with the shared lane table → report `stack_up` →
/// wait for /go → place the call → receive chat text, chunked attachments
/// (voice notes, files), staged photos and video notes on their lanes,
/// POSTing one event per item with its sha256 and the item's raw bytes to
/// /blob (so the Mac can decode what the phone received) → hold until the
/// app hangs up (or the job's hold expires) → drain the blob posts →
/// report `ended` → loop.
///
/// Defines:
///   E2E_RELAY_URI         wss://192.168.2.1:4443/  (the Mac's bridge address)
///   JOURNEY_HUB_URL       http://192.168.2.1:8765  (tools/t2/journey_hub.py)
///   E2E_CONNECT_BUDGET_S  connect + reconnect budget in seconds (300)
library;

// Evidence lines are also printed for a tethered `flutter run`.
// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:call_core/call_core.dart';
import 'package:cryptography/cryptography.dart';
import 'package:device_link/device_link.dart'
    show BundleAdmission, DtnBundle, DtnBundleQueue, LinkMessagePriority;
import 'package:device_link/durable_store.dart' show DurableBundleStore;
import 'package:flutter/material.dart';
import 'package:media_webrtc/media_webrtc.dart' show RawRtcCounters;
import 'package:messaging/messaging.dart';
import 'package:messaging_webrtc_adapter/messaging_webrtc_adapter.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'blackout_forwarder.dart';
import 'support/e2e_support.dart';

const String journeyHubUrl = String.fromEnvironment(
  'JOURNEY_HUB_URL',
  defaultValue: 'http://192.168.2.1:8765',
);
const int journeyConnectBudgetS = int.fromEnvironment(
  'E2E_CONNECT_BUDGET_S',
  defaultValue: 300,
);

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final peer = JourneyPeer();
  runApp(JourneyPeerApp(peer));
  unawaited(peer.run());
}

/// One job handed out by the hub: which key to call, how long to hold.
class JourneyJob {
  final String run;
  final String key;
  final int holdS;

  /// Present for the blackout profile: v1 {bytes, probe_s, lifetime_s}, or
  /// v2 {v:2, plan:[{kind,bytes,n}...], probe_s, lifetime_s, chunk_bytes}
  /// (see BlackoutPlan). The peer then holds signed bundles instead of
  /// placing a call.
  final Map<String, Object?>? blackout;

  const JourneyJob({
    required this.run,
    required this.key,
    required this.holdS,
    this.blackout,
  });

  static JourneyJob? tryParse(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map<String, Object?>) return null;
      final run = decoded['run'];
      final key = decoded['key'];
      final hold = decoded['hold_s'];
      if (run is! String || key is! String || run.isEmpty || key.isEmpty) {
        return null;
      }
      final blackout = decoded['blackout'];
      return JourneyJob(
        run: run,
        key: key,
        holdS: hold is int ? hold : 400,
        blackout: blackout is Map<String, Object?> ? blackout : null,
      );
    } on FormatException {
      return null;
    }
  }
}

class JourneyPeer {
  final ValueNotifier<String> status = ValueNotifier<String>('booting');
  final ValueNotifier<List<String>> events = ValueNotifier<List<String>>([]);
  final HttpClient _http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 3);

  /// Bundle bodies ride a separate client: on a 16 kbit/s gate one 8 KB
  /// chunk is about 4 s of wire time, so its connect and reply deadlines
  /// are far longer than the probe's; a shared client would let the
  /// probe's 3 s connect timeout cut every chunk short.
  final HttpClient _bulkHttp = HttpClient()
    ..connectionTimeout = const Duration(seconds: 10);

  MediaMode? _mode;
  String? _lastRun;

  /// This install's Ed25519 key pair, made at boot; the public key rides
  /// the boot event so the Mac can verify a bundle signed hours later.
  SimpleKeyPair? _keyPair;
  String? _pubkeyB64;

  void _note(String line) {
    final stamped =
        '${DateTime.now().toIso8601String().substring(11, 19)} $line';
    print('JOURNEY_PEER $line');
    final next = List<String>.of(events.value)..add(stamped);
    if (next.length > 40) next.removeRange(0, next.length - 40);
    events.value = next;
  }

  Future<void> run() async {
    // The one microphone prompt: asked here, at launch, so the operator can
    // answer it while the Mac side is still building, and never again for
    // the life of this install.
    _mode = await resolveMediaMode();
    // A blackout job holds the phone for hours with no call to keep it
    // awake; without this the screen locks and iOS suspends the prober.
    try {
      await WakelockPlus.enable();
    } on Object catch (error) {
      _note('wakelock unavailable: $error');
    }
    final keyPair = _keyPair = await Ed25519().newKeyPair();
    _pubkeyB64 = base64Encode((await keyPair.extractPublicKey()).bytes);
    _note('boot media=${_mode!.name} hub=$journeyHubUrl');
    // `blob: true` tells the runner this install posts media bytes to /blob;
    // an older install reports only sha256 receipts. `blackout: true` says
    // it can hold a signed bundle across an outage, and `pubkey` is the
    // Ed25519 public key the Mac verifies that bundle against.
    await _report('boot', <String, Object?>{
      'media': _mode!.name,
      'blob': true,
      'blackout': true,
      'pubkey': _pubkeyB64,
    });
    while (true) {
      final job = await _nextJob();
      if (job == null) {
        status.value = 'waiting for a job (${_mode!.name})';
        await Future<void>.delayed(const Duration(seconds: 1));
        continue;
      }
      _lastRun = job.run;
      await _serve(job);
    }
  }

  Future<JourneyJob?> _nextJob() async {
    try {
      final response = await _http
          .getUrl(Uri.parse('$journeyHubUrl/job'))
          .then((request) => request.close())
          .timeout(const Duration(seconds: 5));
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode != 200) return null;
      final job = JourneyJob.tryParse(body);
      if (job == null || job.run == _lastRun) return null;
      return job;
    } on Object {
      return null;
    }
  }

  Future<bool> _goRaised(String run) async {
    try {
      final response = await _http
          .getUrl(Uri.parse('$journeyHubUrl/go/$run'))
          .then((request) => request.close())
          .timeout(const Duration(seconds: 5));
      await response.drain<void>();
      return response.statusCode == 200;
    } on Object {
      return false;
    }
  }

  /// One JSON line per event to the hub; best effort, never throws — the
  /// call must not depend on the evidence channel.
  Future<void> _report(
    String event,
    Map<String, Object?> fields, {
    String? run,
  }) async {
    final body = jsonEncode(<String, Object?>{
      'event': event,
      'run': run ?? _lastRun,
      'at': DateTime.now().toUtc().toIso8601String(),
      ...fields,
    });
    try {
      final request = await _http
          .postUrl(Uri.parse('$journeyHubUrl/report'))
          .timeout(const Duration(seconds: 5));
      request.headers.contentType = ContentType.json;
      request.write(body);
      final response = await request.close().timeout(
        const Duration(seconds: 5),
      );
      await response.drain<void>();
    } on Object catch (error) {
      print('JOURNEY_PEER report failed event=$event error=$error');
    }
  }

  /// The raw bytes of one received media item to the hub's /blob route, so
  /// the Mac can decode what the phone received instead of trusting a
  /// sha256 receipt alone. Best effort, never throws: one try, then up to
  /// three retries 1 s, 2 s, 4 s apart; true once the hub answered 200.
  ///
  /// The body goes through contentLength + add(bytes): `write` would send
  /// the bytes as chunked text, and the hub compares the sha of exactly
  /// what arrived against the query's sha256.
  Future<bool> _postBlob({
    required String run,
    required String kind,
    required String id,
    required List<int> bytes,
  }) async {
    final sha = contentSha256Hex(bytes);
    final url = Uri.parse(
      '$journeyHubUrl/blob'
      '?run=${Uri.encodeQueryComponent(run)}'
      '&kind=${Uri.encodeQueryComponent(kind)}'
      '&id=${Uri.encodeQueryComponent(id)}'
      '&sha256=${Uri.encodeQueryComponent(sha)}',
    );
    // One try, then up to three retries with these delays between them.
    const delays = [
      Duration(seconds: 1),
      Duration(seconds: 2),
      Duration(seconds: 4),
    ];
    for (var attempt = 0; attempt <= delays.length; attempt++) {
      var code = 0;
      try {
        final request = await _http
            .postUrl(url)
            .timeout(const Duration(seconds: 5));
        request.headers.contentType = ContentType.binary;
        request.contentLength = bytes.length;
        request.add(bytes);
        final response = await request.close().timeout(
          const Duration(seconds: 15),
        );
        code = response.statusCode;
        await response.drain<void>();
      } on Object catch (error) {
        _note('blob kind=$kind id=$id bytes=${bytes.length} error=$error');
      }
      _note(
        'blob kind=$kind id=$id bytes=${bytes.length} status=$code '
        'try=${attempt + 1}',
      );
      if (code == 200) return true;
      // 400 (bad params) and 413 (too big) will not change on a retry;
      // 409 (sha mismatch, a corrupted body in flight) and errors might.
      if (code == 400 || code == 413) return false;
      if (attempt < delays.length) {
        await Future<void>.delayed(delays[attempt]);
      }
    }
    return false;
  }

  Future<void> _serve(JourneyJob job) async {
    if (job.blackout != null) {
      await _serveBlackout(job, job.blackout!);
      return;
    }
    status.value = 'job ${job.run}: preparing';
    _note('job run=${job.run} key=${job.key} hold=${job.holdS}s');
    final relay = await LoopbackRelay.start(); // remote: no in-process server
    final stack = E2eCallStack.build(
      endpoint: relay.endpoint,
      callId: job.key,
      role: CallRole.initiator,
      mode: _mode!,
    );
    final lanes = _Lanes(this, stack, job.run);
    final startedAt = DateTime.now();
    try {
      // The lanes are requested now and resolve once the controller starts
      // the media engine (openDataChannel waits for start); the receivers
      // must exist before the first frame can arrive.
      final lanesReady = lanes.open();
      await _report('stack_up', <String, Object?>{
        'media': _mode!.name,
        'relay': relay.endpoint.toString(),
        'budget_s': journeyConnectBudgetS,
      });
      status.value = 'job ${job.run}: waiting for go';
      final goDeadline = DateTime.now().add(const Duration(minutes: 10));
      while (!await _goRaised(job.run)) {
        if (DateTime.now().isAfter(goDeadline)) {
          throw TimeoutException('GO was never raised for ${job.run}');
        }
        await Future<void>.delayed(const Duration(seconds: 1));
      }
      _note('go: starting the call');
      status.value = 'job ${job.run}: calling';
      unawaited(stack.controller.start());
      await lanesReady;
      final connected = await stack.waitForConnected(
        timeout: Duration(seconds: journeyConnectBudgetS),
      );
      final connectMs = DateTime.now().difference(startedAt).inMilliseconds;
      _note('connected phase=${connected.phase.name} connect_ms=$connectMs');
      await _report('connected', <String, Object?>{
        'phase': connected.phase.name,
        'connect_ms': connectMs,
      });
      status.value = 'job ${job.run}: connected';

      final holdUntil = DateTime.now().add(Duration(seconds: job.holdS));
      while (DateTime.now().isBefore(holdUntil)) {
        await Future<void>.delayed(const Duration(seconds: 2));
        // Terminal FIRST: the sample loop of the old peer test read counters
        // off a port the remote hangup had already closed and failed the
        // whole run on a StateError (latency/loss10/loss60/extreme logs).
        if (stack.controller.state.isTerminal) break;
        final counters = await _counters(stack);
        final elapsed = DateTime.now().difference(startedAt).inSeconds;
        await _report('sample', <String, Object?>{
          't_s': elapsed,
          'phase': stack.controller.state.phase.name,
          'rx': counters?.packetsReceived,
          'lost': counters?.packetsLost,
          'tx': counters?.packetsSent,
        });
      }
      if (!stack.controller.state.isTerminal) {
        _note('hold expired: hanging up');
        await stack.controller.hangUp();
      }
      final done = await stack.controller.done.timeout(
        const Duration(seconds: 30),
      );
      _note('ended phase=${done.phase.name} reason=${done.endReason?.name}');
      // The hub writes job.done on `ended`, and the runner stops waiting
      // then — a blob posted after it is lost, so every post lands first.
      await lanes.drainBlobs();
      await _report('ended', <String, Object?>{
        'phase': done.phase.name,
        'reason': done.endReason?.name,
        'phases': stack.recentPhases(),
        ...lanes.summary(),
      });
    } on Object catch (error) {
      _note(
        'failed error=$error last_phase=${stack.controller.state.phase.name}',
      );
      await lanes.drainBlobs(); // same reason as before `ended`
      await _report('failed', <String, Object?>{
        'error': '$error',
        'last_phase': stack.controller.state.phase.name,
        'phases': stack.recentPhases(),
        ...lanes.summary(),
      });
    } finally {
      await lanes.close();
      await stack.dispose();
      await relay.close();
      status.value = 'job ${job.run}: finished';
    }
  }

  /// The blackout job: no call. A signed bundle of [bytes] is created at T0,
  /// put in the DURABLE store-and-forward queue (survives a process restart),
  /// and the phone probes the hub every [probeS] seconds with one cheap GET.
  /// The first probe that answers opens the queue's flush: the bundle is
  /// POSTed to /bundle, the Mac verifies the Ed25519 signature and records
  /// the arrival. Delivery time is whatever the link allowed — hours, not
  /// seconds — and the row reports it in hours.
  Future<void> _serveBlackout(JourneyJob job, Map<String, Object?> cfg) async {
    _lastRun = job.run;
    final plan = BlackoutPlan.parse(cfg);
    if (plan != null) {
      await _serveBlackoutV2(job, plan);
      return;
    }
    final bytes = cfg['bytes'] is int ? cfg['bytes']! as int : 1024;
    final probeS = cfg['probe_s'] is int ? cfg['probe_s']! as int : 20;
    final lifetimeS = cfg['lifetime_s'] is int
        ? cfg['lifetime_s']! as int
        : 6 * 3600;
    _note(
      'blackout job run=${job.run} bytes=$bytes probe=${probeS}s '
      'lifetime=${lifetimeS}s',
    );
    status.value = 'job ${job.run}: blackout — holding $bytes B';

    final createdMs = DateTime.now().toUtc().millisecondsSinceEpoch;
    final header = utf8.encode(
      jsonEncode({'run': job.run, 'created_ms': createdMs, 'bytes': bytes}),
    );
    final random = Random.secure();
    final payload = Uint8List(bytes);
    payload.setRange(0, min(header.length, bytes), header);
    for (var i = header.length; i < bytes; i++) {
      payload[i] = random.nextInt(256);
    }
    final sha = contentSha256Hex(payload);
    final id = sha.substring(0, 16);
    final signature = await Ed25519().sign(payload, keyPair: _keyPair!);
    final envelope = utf8.encode(
      jsonEncode({
        'run': job.run,
        'id': id,
        'created_ms': createdMs,
        'payload': base64Encode(payload),
        'sig': base64Encode(signature.bytes),
        'pubkey': _pubkeyB64,
      }),
    );
    final store = DurableBundleStore.open(
      File('${Directory.systemTemp.path}/journey_blackout_bundles.jsonl'),
    );
    final queue = DtnBundleQueue(store: store);
    final admission = queue.offer(
      DtnBundle(
        id: id,
        payload: envelope,
        priority: LinkMessagePriority.bulk,
        createdAtMs: createdMs,
        lifetimeMs: lifetimeS * 1000,
      ),
      nowMs: createdMs,
    );
    _note('bundle $id queued ($admission), sha256=$sha');
    // The last event that can leave before the runner cuts the link.
    await _report('blackout_armed', <String, Object?>{
      'id': id,
      'sha256': sha,
      'created_ms': createdMs,
      'bytes': bytes,
      'probe_s': probeS,
      'lifetime_s': lifetimeS,
      'store': 'durable',
    }, run: job.run);

    var probes = 0;
    var reachable = 0;
    int? deliveredMs;
    final deadlineMs = createdMs + lifetimeS * 1000;
    while (DateTime.now().toUtc().millisecondsSinceEpoch < deadlineMs) {
      await Future<void>.delayed(Duration(seconds: probeS));
      probes++;
      final heldS =
          (DateTime.now().toUtc().millisecondsSinceEpoch - createdMs) ~/ 1000;
      status.value =
          'job ${job.run}: holding $bytes B for ${heldS}s, probe $probes';
      if (!await _hubReachable()) continue;
      reachable++;
      final nowMs = DateTime.now().toUtc().millisecondsSinceEpoch;
      final sent = await queue.flush(_postBundle, nowMs: nowMs);
      if (sent > 0) {
        deliveredMs = DateTime.now().toUtc().millisecondsSinceEpoch;
        break;
      }
    }
    if (deliveredMs != null) {
      final latencyS = (deliveredMs - createdMs) / 1000.0;
      _note(
        'bundle $id delivered after ${latencyS.toStringAsFixed(0)}s, '
        'probes=$probes reachable=$reachable',
      );
      status.value = 'job ${job.run}: delivered after ${latencyS ~/ 60} min';
      await _report('ended', <String, Object?>{
        'phase': 'ended',
        'reason': 'bundleDelivered',
        'delivered_ms': deliveredMs,
        'latency_s': latencyS,
        'probes': probes,
        'reachable_probes': reachable,
      }, run: job.run);
    } else {
      _note('bundle $id NOT delivered within ${lifetimeS}s, probes=$probes');
      status.value = 'job ${job.run}: bundle expired undelivered';
      await _report('failed', <String, Object?>{
        'error': 'bundle not delivered within ${lifetimeS}s',
        'last_phase': 'blackout',
        'probes': probes,
        'reachable_probes': reachable,
      }, run: job.run);
    }
  }

  /// The v2 blackout job: the window is a gate, not a probe. A plan of
  /// bundles with real sizes and priorities is signed at T0 and kept in the
  /// durable queue; a 2 s probe (one 60-byte GET) finds the window, and the
  /// first probe that answers flushes the WHOLE queue in priority-then-age
  /// order until the link drops or nothing is left. Bundles larger than the
  /// chunk size travel as chunks with per-chunk acks, so a window that
  /// closes mid-transfer keeps its progress on the hub and the next window
  /// resumes from the first missing chunk. The runner shapes the window at
  /// 16 kbit/s, so bytes delivered per window is a utilization figure.
  Future<void> _serveBlackoutV2(JourneyJob job, BlackoutPlan plan) async {
    final total = plan.items.length;
    if (total == 0) {
      _note('blackout v2 job run=${job.run}: empty plan');
      await _report('failed', <String, Object?>{
        'error': 'blackout v2 plan is empty',
        'last_phase': 'blackout',
        'delivered': 0,
        'remaining': 0,
      }, run: job.run);
      return;
    }
    _note(
      'blackout v2 job run=${job.run} bundles=$total '
      'bytes=${plan.bytesTotal} probe=${plan.probeS}s '
      'chunk=${plan.chunkBytes} lifetime=${plan.lifetimeS}s',
    );
    status.value = 'job ${job.run}: blackout v2 — holding $total bundles';
    // Without the wakelock iOS suspends the app once the screen locks and
    // the probe stops; the state is logged so a gap in the probe count has
    // its explanation on the phone's own event list.
    try {
      _note('wakelock enabled=${await WakelockPlus.enabled}');
    } on Object catch (error) {
      _note('wakelock state unknown: $error');
    }

    final createdMs = DateTime.now().toUtc().millisecondsSinceEpoch;
    final random = Random.secure();
    // One store file per run: a leftover from an earlier run must not ride
    // along, while a restart of the same run resumes its own queue.
    final safeRun = job.run.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final store = DurableBundleStore.open(
      File('${Directory.systemTemp.path}/journey_blackout_v2_$safeRun.jsonl'),
    );
    final queue = DtnBundleQueue(store: store);
    final ids = <String>[];
    final payloadBytes = <String, int>{};
    for (final item in plan.items) {
      final payload = blackoutPayload(
        run: job.run,
        item: item,
        createdMs: createdMs,
        random: random,
      );
      final id = contentSha256Hex(payload).substring(0, 16);
      final signature = await Ed25519().sign(payload, keyPair: _keyPair!);
      final envelope = buildBlackoutEnvelope(
        run: job.run,
        id: id,
        createdMs: createdMs,
        payload: payload,
        signature: signature.bytes,
        pubkeyB64: _pubkeyB64!,
      );
      final admission = queue.offer(
        DtnBundle(
          id: id,
          payload: envelope,
          priority: item.priority,
          createdAtMs: createdMs,
          lifetimeMs: plan.lifetimeS * 1000,
        ),
        nowMs: createdMs,
      );
      if (admission != BundleAdmission.stored) {
        _note('bundle $id ($item) not queued: ${admission.name}');
      }
      ids.add(id);
      payloadBytes[id] = item.bytes;
    }
    _note(
      '${ids.length} bundles queued, '
      '${queue.pendingInDeliveryOrder(createdMs).length} pending',
    );
    // The last event that can leave before the runner cuts the link.
    await _report('blackout_armed', <String, Object?>{
      'v': 2,
      'bundles': total,
      'bytes_total': plan.bytesTotal,
      'ids': ids,
      'created_ms': createdMs,
      'probe_s': plan.probeS,
      'chunk_bytes': plan.chunkBytes,
      'lifetime_s': plan.lifetimeS,
      'store': 'durable',
    }, run: job.run);

    final forwarder = BlackoutForwarder(
      _HubBlackoutTransport(this),
      chunkBytes: plan.chunkBytes,
      log: _note,
    );
    var probes = 0;
    var reachable = 0;
    var delivered = 0;
    var deliveredBytes = 0;
    var deliveredWireBytes = 0;
    int? lastDeliveredMs;
    Future<bool> forward(DtnBundle bundle) async {
      final ok = await forwarder.forward(
        id: bundle.id,
        envelope: bundle.payload,
        sha256: contentSha256Hex(bundle.payload),
      );
      if (ok) {
        delivered++;
        deliveredBytes += payloadBytes[bundle.id] ?? 0;
        deliveredWireBytes += bundle.payload.length;
        lastDeliveredMs = DateTime.now().toUtc().millisecondsSinceEpoch;
        _note(
          'bundle ${bundle.id} delivered ($delivered/$total, '
          '${forwarder.lastChunksPosted} chunks)',
        );
        status.value = 'job ${job.run}: delivered $delivered/$total';
      }
      return ok;
    }

    final deadlineMs = createdMs + plan.lifetimeS * 1000;
    var nowMs = createdMs;
    while (nowMs < deadlineMs) {
      await Future<void>.delayed(Duration(seconds: plan.probeS));
      probes++;
      nowMs = DateTime.now().toUtc().millisecondsSinceEpoch;
      final heldS = (nowMs - createdMs) ~/ 1000;
      status.value =
          'job ${job.run}: $delivered/$total delivered, held ${heldS}s, '
          'probe $probes';
      // The probe and a flush never overlap: the flush is awaited before
      // the next probe, so the 60-byte GET never competes with a chunk for
      // the 16 kbit/s gate.
      if (!await _hubReachable()) continue;
      reachable++;
      await queue.flush(forward, nowMs: nowMs);
      nowMs = DateTime.now().toUtc().millisecondsSinceEpoch;
      if (queue.pendingInDeliveryOrder(nowMs).isEmpty) break;
    }
    final remaining = total - delivered;
    if (remaining == 0 && lastDeliveredMs != null) {
      final latencyS = (lastDeliveredMs! - createdMs) / 1000.0;
      _note(
        'all $total bundles delivered after ${latencyS.toStringAsFixed(0)}s, '
        'probes=$probes reachable=$reachable',
      );
      status.value = 'job ${job.run}: delivered after ${latencyS ~/ 60} min';
      await _report('ended', <String, Object?>{
        'phase': 'ended',
        'reason': 'queueDelivered',
        'delivered': delivered,
        'bytes': deliveredBytes,
        'wire_bytes': deliveredWireBytes,
        'delivered_ms': lastDeliveredMs,
        'latency_s': latencyS,
        'probes': probes,
        'reachable_probes': reachable,
      }, run: job.run);
    } else {
      _note(
        '$remaining of $total bundles NOT delivered within '
        '${plan.lifetimeS}s, probes=$probes',
      );
      status.value = 'job ${job.run}: $remaining bundles expired undelivered';
      await _report('failed', <String, Object?>{
        'error': '$remaining bundles not delivered within ${plan.lifetimeS}s',
        'last_phase': 'blackout',
        'delivered': delivered,
        'remaining': remaining,
        'bytes': deliveredBytes,
        'wire_bytes': deliveredWireBytes,
        'probes': probes,
        'reachable_probes': reachable,
      }, run: job.run);
    }
  }

  /// One whole envelope to /bundle on the bulk client; true on 200. Used by
  /// the v2 forwarder for envelopes that fit in one chunk.
  Future<bool> _postWholeBundle(String id, List<int> envelope) async {
    try {
      final request = await _bulkHttp
          .postUrl(Uri.parse('$journeyHubUrl/bundle'))
          .timeout(const Duration(seconds: 15));
      request.headers.contentType = ContentType.json;
      request.contentLength = envelope.length;
      request.add(envelope);
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      final body = await response.transform(utf8.decoder).join();
      _note('bundle $id posted: ${response.statusCode} ${body.trim()}');
      return response.statusCode == 200;
    } on Object catch (error) {
      _note('bundle $id post failed: $error');
      return false;
    }
  }

  /// GET /have?id=: the chunk indexes the hub holds; null when it could not
  /// be asked.
  Future<List<int>?> _haveChunks(String id) async {
    try {
      final response = await _bulkHttp
          .getUrl(Uri.parse('$journeyHubUrl/have?id=$id'))
          .then((request) => request.close())
          .timeout(const Duration(seconds: 15));
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode != 200) {
        _note('have $id: ${response.statusCode} ${body.trim()}');
        return null;
      }
      final decoded = jsonDecode(body);
      if (decoded is! Map<String, Object?>) return null;
      final have = decoded['have'];
      if (have is! List) return null;
      return [
        for (final idx in have)
          if (idx is int) idx,
      ];
    } on Object catch (error) {
      _note('have $id failed: $error');
      return null;
    }
  }

  /// POST /chunk with the raw bytes: 8 KB is about 4 s on a 16 kbit/s gate,
  /// so the reply deadline is 30 s, not the probe's 4 s.
  Future<ChunkReply> _postChunk({
    required String id,
    required int idx,
    required int n,
    required String sha256,
    required List<int> bytes,
  }) async {
    try {
      final request = await _bulkHttp
          .postUrl(
            Uri.parse(
              '$journeyHubUrl/chunk?id=$id&idx=$idx&n=$n&sha256=$sha256',
            ),
          )
          .timeout(const Duration(seconds: 15));
      request.headers.contentType = ContentType.binary;
      request.contentLength = bytes.length;
      request.add(bytes);
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      final body = (await response.transform(utf8.decoder).join()).trim();
      if (response.statusCode != 200) {
        _note('chunk $id#$idx/$n: ${response.statusCode} $body');
        return ChunkReply.failed;
      }
      if (body.startsWith('complete')) {
        _note('chunk $id#$idx/$n: $body');
        return ChunkReply.complete;
      }
      return ChunkReply.stored;
    } on Object catch (error) {
      _note('chunk $id#$idx/$n failed: $error');
      return ChunkReply.failed;
    }
  }

  /// One cheap GET: the probe that decides whether a window is open.
  Future<bool> _hubReachable() async {
    try {
      final response = await _http
          .getUrl(Uri.parse('$journeyHubUrl/health'))
          .then((request) => request.close())
          .timeout(const Duration(seconds: 4));
      await response.drain<void>();
      return response.statusCode == 200;
    } on Object {
      return false;
    }
  }

  /// The queue's forwarder: the whole signed envelope in one POST; true only
  /// on a 200 so the queue keeps the bundle for the next window otherwise.
  Future<bool> _postBundle(DtnBundle bundle) async {
    try {
      final request = await _http
          .postUrl(Uri.parse('$journeyHubUrl/bundle'))
          .timeout(const Duration(seconds: 5));
      request.headers.contentType = ContentType.json;
      request.contentLength = bundle.payload.length;
      request.add(bundle.payload);
      final response = await request.close().timeout(
        const Duration(seconds: 15),
      );
      final body = await response.transform(utf8.decoder).join();
      _note('bundle ${bundle.id} posted: ${response.statusCode} $body');
      return response.statusCode == 200;
    } on Object catch (error) {
      _note('bundle ${bundle.id} post failed: $error');
      return false;
    }
  }

  static Future<RawRtcCounters?> _counters(E2eCallStack stack) async {
    final port = stack.port;
    if (port == null) return null;
    try {
      return await port.readStatsCounters().timeout(
        const Duration(seconds: 5),
        onTimeout: () => null,
      );
    } on StateError {
      return null; // closed under us: the call just ended
    }
  }
}

/// The v2 forwarder's view of the hub: the three routes on the peer's
/// bulk client.
class _HubBlackoutTransport implements BlackoutTransport {
  _HubBlackoutTransport(this._peer);

  final JourneyPeer _peer;

  @override
  Future<bool> postWhole(String id, List<int> envelope) =>
      _peer._postWholeBundle(id, envelope);

  @override
  Future<List<int>?> have(String id) => _peer._haveChunks(id);

  @override
  Future<ChunkReply> postChunk({
    required String id,
    required int idx,
    required int n,
    required String sha256,
    required List<int> bytes,
  }) => _peer._postChunk(id: id, idx: idx, n: n, sha256: sha256, bytes: bytes);
}

/// The receiving half of every lane, reporting each verified item.
class _Lanes {
  _Lanes(this._peer, this._stack, this._run);

  final JourneyPeer _peer;
  final E2eCallStack _stack;
  final String _run;

  ReliableMessenger? _messenger;
  Timer? _ticker;
  final AttachmentReceiver _attachments = AttachmentReceiver();
  StagedPhotoReceiver? _photos;
  VideoNoteReceiver? _videos;
  final List<StreamSubscription<Object?>> _subs = [];
  int texts = 0;
  int attachments = 0;
  int photos = 0;
  int videos = 0;

  /// Every /blob post fired so far, in receipt order; `drainBlobs` awaits
  /// them before the terminal report.
  final List<Future<bool>> _blobs = [];
  int blobsPosted = 0;
  int blobsFailed = 0;

  /// Fires one /blob post for a verified item and queues it. Never throws:
  /// this runs inside lane callbacks, and `_postBlob` swallows its errors.
  void _post(String kind, String id, List<int> bytes) {
    final posted = _peer._postBlob(run: _run, kind: kind, id: id, bytes: bytes);
    _blobs.add(
      posted.then((ok) {
        if (ok) {
          blobsPosted++;
        } else {
          blobsFailed++;
        }
        return ok;
      }),
    );
  }

  /// Waits for every queued /blob post, at most 30 s overall; never throws.
  /// A post still in flight at the cap counts as neither posted nor
  /// failed — the summary shows the gap against the item counts.
  Future<void> drainBlobs() async {
    if (_blobs.isEmpty) return;
    try {
      await Future.wait(_blobs).timeout(
        const Duration(seconds: 30),
        onTimeout: () {
          _peer._note(
            'blob drain timed out: posted=$blobsPosted failed=$blobsFailed '
            'of ${_blobs.length}',
          );
          return const <bool>[];
        },
      );
    } on Object catch (error) {
      _peer._note('blob drain error=$error');
    }
  }

  Future<void> open() async {
    final chatPort = MediaChannelDataPort(
      await _stack.media.openDataChannel(CallLanes.chat),
    );
    final photoPort = MediaChannelDataPort(
      await _stack.media.openDataChannel(CallLanes.photo),
      maxPendingFrames: 128,
    );
    final videoPort = MediaChannelDataPort(
      await _stack.media.openDataChannel(CallLanes.video),
      maxPendingFrames: 128,
    );
    final messenger = _messenger = ReliableMessenger(chatPort, peerId: 'phone');
    _ticker = Timer.periodic(const Duration(milliseconds: 500), (_) {
      unawaited(messenger.tick());
    });
    final photoRx = _photos = StagedPhotoReceiver.arq(photoPort);
    final videoRx = _videos = VideoNoteReceiver(videoPort);

    _subs.add(
      messenger.incoming.listen((message) {
        if (photoRx.offerText(message.text)) return;
        if (videoRx.offerText(message.text)) return;
        if (_attachments.offer(message.text)) return;
        texts++;
        _peer._note('text id=${message.id} "${message.text}"');
        unawaited(
          _peer._report('text', <String, Object?>{
            'id': message.id,
            'text': message.text,
            'sha256': contentSha256Hex(utf8.encode(message.text)),
          }, run: _run),
        );
        // The app shows the reply as an incoming bubble on the recording.
        unawaited(messenger.send('echo: ${message.text}'));
      }),
    );
    _subs.add(
      _attachments.completed.listen((attachment) {
        attachments++;
        final sha = contentSha256Hex(attachment.bytes);
        _peer._note(
          'attachment id=${attachment.id} kind=${attachment.kind.name} '
          'bytes=${attachment.bytes.length} sha256=$sha',
        );
        unawaited(
          _peer._report('attachment', <String, Object?>{
            'id': attachment.id,
            'kind': attachment.kind.name,
            'content_type': attachment.contentType,
            'bytes': attachment.bytes.length,
            'sha256': sha,
            'verified': true, // chunk reassembly is complete; sha reported
          }, run: _run),
        );
        // A voice note is an audio attachment; anything else is a file.
        _post(
          attachment.contentType.startsWith('audio/') ? 'voice' : 'file',
          attachment.id,
          attachment.bytes,
        );
      }),
    );
    _subs.add(
      photoRx.updates.listen((update) {
        final original = update.state.original;
        _peer._note(
          'photo id=${update.photoId} stage=${update.stage.name} '
          'verified=${update.state.sha256Verified}',
        );
        if (update.stage != PhotoStage.originalVerified) return;
        photos++;
        unawaited(
          _peer._report('photo', <String, Object?>{
            'id': update.photoId,
            'stage': update.stage.name,
            'bytes': original?.length,
            'sha256': update.state.announcement.sha256Hex,
            'verified': update.state.sha256Verified,
            'deduplicated': update.deduplicated,
          }, run: _run),
        );
        // Only the verified original goes to /blob — the preview stage
        // carries different bytes and would break the Mac's sha chain.
        if (original == null) {
          _peer._note('photo id=${update.photoId} verified without bytes');
          return;
        }
        _post('photo', update.photoId, original);
      }),
    );
    _subs.add(
      videoRx.updates.listen((update) {
        _peer._note('video id=${update.videoId} stage=${update.stage.name}');
        if (update.stage == VideoNoteStage.announced) return;
        if (update.stage == VideoNoteStage.verified) videos++;
        unawaited(
          _peer._report('video', <String, Object?>{
            'id': update.videoId,
            'stage': update.stage.name,
            'bytes': update.state.bytes?.length,
            'sha256': update.state.announcement.sha256Hex,
            'verified': update.stage == VideoNoteStage.verified,
          }, run: _run),
        );
        if (update.stage != VideoNoteStage.verified) return;
        final bytes = update.state.bytes;
        if (bytes == null) {
          _peer._note('video id=${update.videoId} verified without bytes');
          return;
        }
        _post('video', update.videoId, bytes);
      }),
    );
  }

  Map<String, Object?> summary() => <String, Object?>{
    'texts': texts,
    'attachments': attachments,
    'photos': photos,
    'videos': videos,
    'blobs_posted': blobsPosted,
    'blobs_failed': blobsFailed,
  };

  Future<void> close() async {
    _ticker?.cancel();
    for (final sub in _subs) {
      await sub.cancel();
    }
    _subs.clear();
    await _photos?.close();
    await _videos?.close();
    await _messenger?.close();
  }
}

class JourneyPeerApp extends StatelessWidget {
  const JourneyPeerApp(this.peer, {super.key});

  final JourneyPeer peer;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Journey peer',
      theme: ThemeData.dark(useMaterial3: true),
      home: Scaffold(
        appBar: AppBar(title: const Text('Journey peer (phone side)')),
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ValueListenableBuilder<String>(
                valueListenable: peer.status,
                builder: (context, value, _) =>
                    Text(value, style: Theme.of(context).textTheme.titleLarge),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: ValueListenableBuilder<List<String>>(
                  valueListenable: peer.events,
                  builder: (context, lines, _) => ListView(
                    reverse: true,
                    children: [
                      for (final line in lines.reversed)
                        Text(
                          line,
                          style: const TextStyle(
                            fontFamily: 'Menlo',
                            fontSize: 12,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
