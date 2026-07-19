/// Drives `ChatScreen` over a real [ReliableMessenger].
///
/// Two transports, same messaging stack either way:
/// - Default (no `callChannelPort`): an in-process [LoopbackPort] pair with
///   an auto-replying peer — genuine reliable delivery/ack/de-dup, zero
///   network, so the demo works standalone.
/// - Call mode (`callChannelPort` from `CallSessionHandle.openChatPort`):
///   the messenger rides the live call's own data channel; the remote human
///   is the peer, so there is no local echo side and incoming attachments
///   are reassembled off the wire.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:live_captions/live_captions.dart';
import 'package:messaging/messaging.dart';

import 'chat_screen.dart';
import 'loopback_port.dart';

class ChatDemoController extends ChangeNotifier {
  ChatDemoController({
    DataChannelPort? callChannelPort,
    this._attachmentPicker,
  }) {
    final DataChannelPort localPort;
    if (callChannelPort != null) {
      localPort = callChannelPort;
    } else {
      final (loopLocal, loopPeer) = pairLoopbackPorts();
      localPort = loopLocal;
      final peer = _peer = ReliableMessenger(loopPeer, peerId: 'peer');
      _peerSub = peer.incoming.listen((message) {
        if (_peerAttachments.offer(message.text)) {
          return; // an attachment chunk, not chat text — already consumed
        }
        if (CaptionFrame.tryDecode(message.text) != null) {
          return; // caption frames are never echoed as chat
        }
        unawaited(peer.send('echo: ${message.text}'));
      });
    }
    _local = ReliableMessenger(localPort, peerId: localSenderId);

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
      if (_localAttachments.offer(message.text)) {
        return; // reassembling; the completed stream emits the bubble
      }
      if (_captionReceiver.offer(message.text)) {
        return; // a live caption — rendered in the caption strip, not a bubble
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

  ChatMessage _peerPlaceholder(String text) => ChatMessage(
    id: 'peer-recv-${_localSeq++}',
    senderId: 'peer',
    seq: _localSeq,
    sentAtMs: DateTime.now().millisecondsSinceEpoch,
    text: text,
  );

  Future<void> sendText(String text) async {
    final message = await _local.send(text);
    entries.add(ChatEntry(message: message));
    notifyListeners();
  }

  /// Picker injected at construction (`pickAttachmentFile` in the app, a
  /// fake in widget tests); null hides the chat screen's attach button.
  final Future<Attachment?> Function()? _attachmentPicker;

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
    entries.add(
      ChatEntry(
        message: _localPlaceholder('[${attachment.kind.name}]'),
        attachment: attachment,
      ),
    );
    notifyListeners();
    await sendAttachmentWithProgress(attachment);
  }

  /// Sends [attachment] over the live messenger, mirroring per-chunk
  /// progress into [attachmentProgress] for the bubble's progress bar.
  Future<void> sendAttachmentWithProgress(Attachment attachment) async {
    final handle = startAttachmentSend(_local, attachment);
    final sub = handle.progress.listen((p) {
      attachmentProgress[attachment.id] = p.fraction;
      notifyListeners();
    });
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
  Future<void> _seedDemoAttachments() async {
    try {
      final photo = Attachment(
        id: 'demo-photo',
        kind: MediaKind.image,
        contentType: 'image/png',
        bytes: demoTinyPngBytes,
      );
      entries.add(
        ChatEntry(message: _localPlaceholder('[photo]'), attachment: photo),
      );
      notifyListeners();
      await sendAttachmentWithProgress(photo);

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
    unawaited(_local.close());
    unawaited(_peer?.close());
    super.dispose();
  }
}
