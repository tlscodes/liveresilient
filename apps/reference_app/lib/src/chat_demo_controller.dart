/// Drives `ChatScreen` over a real [ReliableMessenger].
///
/// Two transports, same messaging stack either way:
/// - Default (no `callChannelPort`): an in-process [LoopbackPort] pair with
///   an auto-replying peer — genuine reliable delivery/ack/de-dup, zero
///   network, so the demo works standalone. Staged photos ride a SECOND
///   loopback pair as their binary lane; the visible incoming ladder is the
///   peer end's receiver, so sending a photo demonstrates the real
///   three-rung arrival (thumbhash → preview → sha-verified original).
/// - Call mode (`callChannelPort` from `CallSessionHandle.openChatPort`):
///   the messenger rides the live call's own data channel; the remote human
///   is the peer. Staged photos additionally need a `photoLanePort` (a
///   second data channel); without one the photo button stays hidden — no
///   half-wired sends.
library;

import 'dart:async';
import 'dart:convert';

import 'package:connection_orchestrator/connection_orchestrator.dart';
import 'package:flutter/foundation.dart';
import 'package:live_captions/live_captions.dart';
import 'package:messaging/messaging.dart';

import 'attachment_route_wiring.dart';
import 'chat_screen.dart';
import 'intelligence/intelligence_hub.dart';
import 'loopback_port.dart';
import 'photo_source.dart';

class ChatDemoController extends ChangeNotifier {
  ChatDemoController({
    DataChannelPort? callChannelPort,
    DataChannelPort? photoLanePort,
    ConnectionFabric? intelligenceFabric,
    this._hub,
    this._photoPicker,
    this._photoIngest,
    this._attachmentPicker,
    this._audioPlayer,
  }) : _fabric = intelligenceFabric {
    final DataChannelPort localPort;
    if (callChannelPort != null) {
      localPort = callChannelPort;
      if (photoLanePort != null) {
        // The lane frames (magic-discriminated) and the messenger's JSON
        // frames partition cleanly, so sender and receiver share the port.
        _photoSender = StagedPhotoSender.arq(
          photoLanePort,
          announce: _announcePhoto,
          retransmitAfter: const Duration(milliseconds: 700),
        );
        _photoReceiver = StagedPhotoReceiver.arq(photoLanePort);
      }
    } else {
      final (loopLocal, loopPeer) = pairLoopbackPorts();
      localPort = loopLocal;
      final peer = _peer = ReliableMessenger(loopPeer, peerId: 'peer');
      _peerSub = peer.incoming.listen((message) {
        if (_photoReceiver?.offerText(message.text) ?? false) {
          return; // a photo announcement — the staged ladder consumes it
        }
        if (_peerAttachments.offer(message.text)) {
          return; // an attachment chunk, not chat text — already consumed
        }
        if (CaptionFrame.tryDecode(message.text) != null) {
          return; // caption frames are never echoed as chat
        }
        unawaited(peer.send('echo: ${message.text}'));
      });
      // The photo binary lane: local end sends, peer end receives — the
      // incoming ladder shown in the transcript is the peer's genuine
      // receive experience, not a local shortcut.
      final (photoLaneLocal, photoLanePeerEnd) = pairLoopbackPorts();
      _photoSender = StagedPhotoSender.arq(
        photoLaneLocal,
        announce: _announcePhoto,
        retransmitAfter: const Duration(milliseconds: 300),
      );
      _photoReceiver = StagedPhotoReceiver.arq(photoLanePeerEnd);
    }
    _local = ReliableMessenger(localPort, peerId: localSenderId);

    _photoUpdatesSub = _photoReceiver?.updates.listen(_onIncomingPhotoUpdate);

    _deliverySub = _local.deliveries.listen((event) {
      final (id, state) = event;
      deliveryStates[id] = state;
      notifyListeners();
    });

    _captionSub = _captionReceiver.received.listen((caption) {
      _captionLog.apply(caption);
      notifyListeners();
    });

    _localSub = _local.incoming.listen((message) {
      if (_photoReceiver != null &&
          _peer == null &&
          _photoReceiver!.offerText(message.text)) {
        return; // call mode: the announcement arrived from the remote human
      }
      if (_localAttachments.offer(message.text)) {
        return; // reassembling; the completed stream emits the bubble
      }
      if (_captionReceiver.offer(message.text)) {
        return; // a live caption — rendered in the caption strip, not a bubble
      }
      if (!_receivedLedger.record(message.id)) {
        return; // duplicate from dual-send/replicate/relay — one bubble only
      }
      entries.add(ChatEntry(message: message));
      notifyListeners();
    });
    _localAttachmentsSub = _localAttachments.completed.listen((attachment) {
      entries.add(
        ChatEntry(
          message: _peerPlaceholder('[${attachment.kind.name}]'),
          attachment: attachment,
        ),
      );
      notifyListeners();
    });

    if (callChannelPort == null) {
      unawaited(_seedDemoAttachments());
      _seedDemoCaptions();
    }

    // The messaging core is deliberately timer-free (deterministic tests);
    // the APP owns the clock. Without this driver, retransmits and
    // failed-delivery marking would never run — sends into a dropped
    // channel would stay silently pending forever.
    _ticker = Timer.periodic(const Duration(milliseconds: 500), (_) {
      unawaited(_local.tick());
      unawaited(_peer?.tick());
    });
  }

  Timer? _ticker;

  final String localSenderId = 'me';
  final List<ChatEntry> entries = [];

  /// Ack outcome per outbound message id (`ChatScreen` reads this to draw
  /// the per-bubble marker); an outbound id absent here is still pending.
  final Map<String, DeliveryState> deliveryStates = {};

  /// Outbound transfer progress per attachment id, 0.0 → 1.0 (`ChatScreen`
  /// draws the bubble's progress bar while < 1.0).
  final Map<String, double> attachmentProgress = {};

  /// Live captions received over the data channel (call mode) or produced
  /// by the demo pipeline (loopback mode), for the caption strip.
  List<Caption> get captions => _captionLog.entries;

  final CaptionReceiver _captionReceiver = CaptionReceiver();
  final CaptionLog _captionLog = CaptionLog();
  late final StreamSubscription<Caption> _captionSub;
  CaptionPipeline? _demoCaptionPipeline;
  StreamSubscription<Caption>? _demoCaptionSub;

  /// Loopback-demo only: runs two English lines through the REAL
  /// translation pipeline (fixed phrase table, no network) so the running
  /// app shows the caption strip working. Call mode never uses this — there
  /// captions arrive off the wire via [CaptionReceiver].
  void _seedDemoCaptions() {
    final pipeline = _demoCaptionPipeline = CaptionPipeline(
      translator: const FixedMapTranslator({
        'fa:Welcome to the live session.': 'به نشست زنده خوش آمدید.',
        'fa:Captions are translated on the fly.':
            'زیرنویس‌ها هم‌زمان ترجمه می‌شوند.',
      }),
      targetLanguages: ['fa'],
    );
    _demoCaptionSub = pipeline.captions.listen((caption) {
      _captionLog.apply(caption);
      notifyListeners();
    });
    pipeline
      ..add(
        TranscriptSegment(
          id: 'demo-cap-1',
          seq: 0,
          lang: 'en',
          text: 'Welcome to the live session.',
          isFinal: true,
          startMs: 0,
        ),
      )
      ..add(
        TranscriptSegment(
          id: 'demo-cap-2',
          seq: 1,
          lang: 'en',
          text: 'Captions are translated on the fly.',
          isFinal: true,
          startMs: 1500,
        ),
      );
  }

  late final ReliableMessenger _local;
  ReliableMessenger? _peer;
  late final StreamSubscription<ChatMessage> _localSub;
  late final StreamSubscription<(String, DeliveryState)> _deliverySub;
  StreamSubscription<ChatMessage>? _peerSub;
  late final StreamSubscription<Attachment> _localAttachmentsSub;
  final AttachmentReceiver _peerAttachments = AttachmentReceiver();
  final AttachmentReceiver _localAttachments = AttachmentReceiver();
  int _localSeq = 0;

  // ── Staged photo pipeline (RIG_GUIDE §0.2 item 1) ──────────────────────

  final Future<Uint8List?> Function(PhotoSource source)? _photoPicker;
  final Future<StagedPhotoArtifacts> Function(Uint8List raw)? _photoIngest;
  StagedPhotoSender? _photoSender;
  StagedPhotoReceiver? _photoReceiver;
  StreamSubscription<StagedPhotoUpdate>? _photoUpdatesSub;
  final Set<String> _incomingPhotoBubbles = {};

  /// Sender-side staged photo status by photoId (my bubbles' data source).
  final Map<String, OutgoingPhotoStatus> outgoingPhotos = {};

  /// Receiver-side staged photo ladders by photoId (peer bubbles).
  Map<String, StagedPhotoState> get incomingPhotos =>
      _photoReceiver?.photos ?? const {};

  /// Whether [pickAndSendPhoto] can do anything (drives button visibility).
  bool get canPickPhoto =>
      _photoPicker != null && _photoIngest != null && _photoSender != null;

  Future<void> _announcePhoto(String text) async {
    await _local.send(text);
  }

  void _onIncomingPhotoUpdate(StagedPhotoUpdate update) {
    if (_incomingPhotoBubbles.add(update.photoId)) {
      entries.add(
        ChatEntry(
          message: _peerPlaceholder('[photo]'),
          photoId: update.photoId,
        ),
      );
    }
    notifyListeners();
  }

  /// Runs the photo picker for [source], encodes the three staged
  /// artifacts, and delivers them: announcement (thumbhash inside) on the
  /// reliable text path, then preview, then sha-verified original on the
  /// binary lane. Re-picking the same photo is answered from the far
  /// side's held bytes — the content-addressing dividend.
  Future<void> pickAndSendPhoto(PhotoSource source) async {
    final picker = _photoPicker;
    if (picker == null || !canPickPhoto) return;
    final raw = await picker(source);
    if (raw == null) return; // canceled
    await _sendStagedFromRaw(raw);
  }

  /// Encodes raw image bytes and delivers them over the staged pipeline —
  /// the ONLY photo send path (§0.2 law: photos never ride base64 text).
  Future<void> _sendStagedFromRaw(Uint8List raw) async {
    final ingest = _photoIngest;
    final sender = _photoSender;
    if (ingest == null || sender == null) return;
    final artifacts = await ingest(raw);
    final announcement = PhotoAnnouncement.fromArtifacts(artifacts);
    final status = outgoingPhotos.putIfAbsent(
      announcement.photoId,
      () => OutgoingPhotoStatus(announcement.photoId, artifacts.original),
    );
    status
      ..done = false
      ..failed = false;
    final alreadyBubbled = entries.any(
      (e) =>
          e.photoId == announcement.photoId &&
          e.message.senderId == localSenderId,
    );
    if (!alreadyBubbled) {
      entries.add(
        ChatEntry(
          message: _localPlaceholder('[photo]'),
          photoId: announcement.photoId,
        ),
      );
    }
    notifyListeners();
    sender.onStage = (id, stage) {
      outgoingPhotos[id]?.stage = stage;
      notifyListeners();
    };
    try {
      final result = await sender.deliver(artifacts);
      status
        ..done = true
        ..deduplicated = result.deduplicated;
      // sender.lane names the lane that actually carried the photo — today
      // always 'arq' here (the fountain switch lives with rig callers);
      // recorded honestly rather than inventing a switch at this site.
      _hub?.recordDelivery(success: true, choice: sender.lane.name);
    } catch (_) {
      status.failed = true;
      _hub?.recordDelivery(success: false, choice: sender.lane.name);
    }
    notifyListeners();
  }

  /// The app's live connectivity brain. When present, every real user send
  /// is also offered to the fabric so the intelligence observes actual
  /// traffic — learning per (place, network), updating the snapshot/trend,
  /// and letting the director narrate and self-heal on live activity rather
  /// than only on the boot probe. Reliable delivery/ack stays owned by
  /// [ReliableMessenger]; the fabric is an intelligence tap, not the wire.
  final ConnectionFabric? _fabric;

  /// Personal-learning tap: real delivery outcomes train the lane-choice
  /// brain and are journaled for the narrator. Optional; absent in most
  /// widget tests — zero behavior change without it.
  final IntelligenceHub? _hub;

  /// Receive-side dedup: dual-send, replicate, and relay paths may hand
  /// the same message id over more than once — the user sees one bubble.
  final DeliveryLedger _receivedLedger = DeliveryLedger();

  Future<void> sendText(String text) async {
    final message = await _local.send(text);
    entries.add(ChatEntry(message: message));
    notifyListeners();
    final fabric = _fabric;
    if (fabric != null) {
      // Best-effort intelligence tap: never let a fabric hiccup break the
      // user's chat send.
      // .then (not await): chat_fabric_tap_test pins the send's ordering.
      unawaited(
        fabric
            .deliver(utf8.encode(text), bundleId: message.id)
            .then((outcome) {
              _hub?.recordDelivery(
                success: outcome == DeliveryOutcome.sentLive,
                choice: 'arq',
              );
              return outcome;
            })
            .catchError((Object _) => DeliveryOutcome.queuedForLater),
      );
    }
  }

  /// Picker injected at construction (`pickAttachmentFile` in the app, a
  /// fake in widget tests); null hides the chat screen's attach button.
  final Future<Attachment?> Function()? _attachmentPicker;

  /// Platform audio output for voice notes / recovered audio. Injectable:
  /// production supplies a decoder+player, tests a recorder fake. Null =
  /// bubbles render without playback (CI hardware has no audio out).
  final Future<void> Function(Attachment attachment)? _audioPlayer;

  /// Id of the most recently played voice attachment (UI badge + tests).
  String? lastPlayedAudioId;

  /// Plays a voice attachment through the injected player, if any.
  void playAudio(Attachment attachment) {
    lastPlayedAudioId = attachment.id;
    notifyListeners();
    final player = _audioPlayer;
    if (player != null) {
      unawaited(player(attachment));
    }
  }

  /// Whether [pickAndSendAttachment] can do anything (drives button
  /// visibility).
  bool get canPickAttachment => _attachmentPicker != null;

  /// Runs the injected picker; on a chosen file, adds the bubble and
  /// transfers it over the live channel with per-chunk progress.
  Future<void> pickAndSendAttachment() async {
    final picker = _attachmentPicker;
    if (picker == null) return;
    final attachment = await picker();
    if (attachment == null) return; // canceled
    if (attachment.kind == MediaKind.image) {
      // §0.2 law: a photo NEVER rides the base64 text path. An image picked
      // through the generic attach dialog re-routes onto the staged
      // pipeline; without a photo lane it is refused, not downgraded.
      await _sendStagedFromRaw(Uint8List.fromList(attachment.bytes));
      return;
    }
    entries.add(
      ChatEntry(
        message: _localPlaceholder('[${attachment.kind.name}]'),
        attachment: attachment,
      ),
    );
    notifyListeners();
    await sendAttachmentWithProgress(attachment);
  }

  /// The routing question, asked on every real attachment send.
  ///
  /// SHADOW MODE, ON PURPOSE — for the OLD base64 attachment path.
  /// `MediaSendRouter` decides whether this payload belongs on the
  /// cliff-free path; the answer is recorded and the transfer still goes
  /// the acknowledged way. The staged PHOTO pipeline above is the first
  /// consumer that actually rides the binary lane end-to-end (the
  /// receive-side content-address router now exists there); generic file
  /// attachments will follow once their receive side is wired the same way.
  late final AttachmentRouteAdvisor _routeAdvisor = buildAttachmentRouteAdvisor(
    onDecision: (decision) => lastRouteDecision = decision,
  );

  /// What the router said about the most recent attachment. Surfaced so the
  /// decision is observable in a running app rather than only in a log.
  AttachmentRouteDecision? lastRouteDecision;

  /// Sends [attachment] over the live messenger, mirroring per-chunk
  /// progress into [attachmentProgress] for the bubble's progress bar.
  Future<void> sendAttachmentWithProgress(Attachment attachment) async {
    final handle = startAttachmentSend(
      _local,
      attachment,
      routeAdvisor: _routeAdvisor,
    );
    final sub = handle.progress.listen((p) {
      attachmentProgress[attachment.id] = p.fraction;
      notifyListeners();
    });
    final fabric = _fabric;
    if (fabric != null) {
      // Resilience tap for large payloads: the fabric carries the bytes
      // as a resumable, parity-protected chunked transfer, so if the
      // live channel dies mid-file the DTN queue + self-resume finish it
      // on recovery. Best-effort: never breaks the user's send.
      unawaited(
        fabric
            .deliverChunked(attachment.bytes, transferId: attachment.id)
            .catchError(
              (Object _) => ResumableTransfer(
                transferId: attachment.id,
                payload: attachment.bytes,
              ),
            ),
      );
    }
    try {
      await handle.done;
    } finally {
      await sub.cancel();
    }
  }

  /// Seeds one image + one file attachment through the real chunker/
  /// reassembler path, so the running app shows both bubble kinds without
  /// requiring a UI attach button. Errors are swallowed — this is
  /// demo-only seeding, never allowed to crash the app.
  /// Sends a voice note recorded for [length] through the REAL attachment
  /// pipeline (chunker, live loopback channel, per-chunk progress, ack) —
  /// the transfer truth in the bubble is genuine. The AUDIO CONTENT is a
  /// demo placeholder sized to the recording length: real microphone
  /// capture is a dated blocker (no recorder dependency this phase), same
  /// honesty pattern as the seeded demo attachments below.
  Future<void> sendVoiceNote(Duration length) async {
    final seconds = length.inMilliseconds / 1000.0;
    final voice = Attachment(
      id: 'voice-${DateTime.now().millisecondsSinceEpoch}',
      kind: MediaKind.file,
      contentType: 'audio/demo-placeholder',
      bytes: List<int>.filled((4000 * seconds).round().clamp(800, 240000), 0),
    );
    entries.add(
      ChatEntry(message: _localPlaceholder('[voice]'), attachment: voice),
    );
    notifyListeners();
    await sendAttachmentWithProgress(voice);
  }

  Future<void> _seedDemoAttachments() async {
    try {
      // The photo seed rides the STAGED pipeline (never base64 — §0.2 law);
      // bare test controllers without an injected ingest simply skip it.
      if (canPickPhoto) {
        await _sendStagedFromRaw(Uint8List.fromList(demoTinyPngBytes));
      }

      final file = Attachment(
        id: 'demo-file',
        kind: MediaKind.file,
        contentType: 'application/pdf',
        bytes: List<int>.filled(2048, 0),
      );
      entries.add(
        ChatEntry(message: _localPlaceholder('[file]'), attachment: file),
      );
      notifyListeners();
      await sendAttachmentWithProgress(file);
    } catch (_) {
      // Demo seeding is best-effort only.
    }
  }

  ChatMessage _localPlaceholder(String text) => ChatMessage(
    id: '$localSenderId-demo-${_localSeq++}',
    senderId: localSenderId,
    seq: _localSeq,
    sentAtMs: DateTime.now().millisecondsSinceEpoch,
    text: text,
  );

  ChatMessage _peerPlaceholder(String text) => ChatMessage(
    id: 'peer-recv-${_localSeq++}',
    senderId: 'peer',
    seq: _localSeq,
    sentAtMs: DateTime.now().millisecondsSinceEpoch,
    text: text,
  );

  @override
  void dispose() {
    _ticker?.cancel();
    unawaited(_captionSub.cancel());
    unawaited(_demoCaptionSub?.cancel());
    unawaited(_demoCaptionPipeline?.close());
    unawaited(_captionReceiver.close());
    unawaited(_deliverySub.cancel());
    unawaited(_localSub.cancel());
    unawaited(_peerSub?.cancel());
    unawaited(_localAttachmentsSub.cancel());
    unawaited(_photoUpdatesSub?.cancel());
    unawaited(_photoReceiver?.close());
    unawaited(_local.close());
    unawaited(_peer?.close());
    super.dispose();
  }
}
