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

import 'package:call_core/call_core.dart';
import 'package:flutter/material.dart';
import 'package:media_webrtc/media_webrtc.dart' show RawRtcCounters;
import 'package:messaging/messaging.dart';
import 'package:messaging_webrtc_adapter/messaging_webrtc_adapter.dart';

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

  const JourneyJob({required this.run, required this.key, required this.holdS});

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
      return JourneyJob(run: run, key: key, holdS: hold is int ? hold : 400);
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

  MediaMode? _mode;
  String? _lastRun;

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
    _note('boot media=${_mode!.name} hub=$journeyHubUrl');
    // `blob: true` tells the runner this install posts media bytes to /blob;
    // an older install reports only sha256 receipts.
    await _report('boot', <String, Object?>{
      'media': _mode!.name,
      'blob': true,
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
