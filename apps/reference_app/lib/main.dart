/// Reference app: a two-tab demo (Call / Chat) that runs standalone, with
/// no server, camera, or network required — every screen is driven by
/// plain state this file owns. Real device/network wiring
/// (`buildWebRtcCallSession`) is kept available but only from the
/// clearly-marked dev entry point at the bottom of this file.
library;

import 'dart:async';

import 'package:call_core/call_core.dart';
import 'package:flutter/material.dart';
import 'package:messaging/messaging.dart';

import 'src/attachment_picker.dart';
import 'src/call_screen.dart';
import 'src/call_session.dart';
import 'src/chat_screen.dart';
import 'src/loopback_port.dart';
import 'src/theme.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'VoiceCallKit Reference',
      theme: buildAppTheme(Brightness.light),
      darkTheme: buildAppTheme(Brightness.dark),
      home: const HomePage(),
    );
  }
}

/// Root scaffold: a [NavigationBar] switching between the Call and Chat
/// tabs. Owns both tabs' state so the screens themselves stay pure-data.
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _index = 0;
  final CallDemoController _call = CallDemoController();
  final ChatDemoController _chat = ChatDemoController(
    attachmentPicker: pickAttachmentFile,
  );

  @override
  void initState() {
    super.initState();
    _call.addListener(_onChanged);
    _chat.addListener(_onChanged);
  }

  void _onChanged() => setState(() {});

  @override
  void dispose() {
    _call.removeListener(_onChanged);
    _chat.removeListener(_onChanged);
    _call.dispose();
    _chat.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pages = <Widget>[
      CallScreen(
        phase: _call.phase,
        reconnectAttempt: _call.reconnectAttempt,
        endReason: _call.endReason,
        audioOnly: _call.audioOnly,
        onCall: _call.canCall ? _call.placeCall : null,
        onHangUp: _call.canHangUp ? _call.hangUp : null,
      ),
      ChatScreen(
        entries: _chat.entries,
        localSenderId: _chat.localSenderId,
        onSend: _chat.sendText,
        deliveryStates: _chat.deliveryStates,
        attachmentProgress: _chat.attachmentProgress,
        onPickAttachment: () => unawaited(_chat.pickAndSendAttachment()),
      ),
    ];
    return Scaffold(
      appBar: AppBar(title: Text(_index == 0 ? 'Call' : 'Chat')),
      body: pages[_index],
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (value) => setState(() => _index = value),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.call), label: 'Call'),
          NavigationDestination(icon: Icon(Icons.chat_bubble), label: 'Chat'),
        ],
      ),
    );
  }
}

/// Drives [CallScreen] with a simulated call lifecycle — no signaling, no
/// media session, no network. Real calls go through [devConnectToLocalRelay]
/// instead; this controller only produces the plain [CallPhase] data the
/// screen renders.
class CallDemoController extends ChangeNotifier {
  CallPhase phase = CallPhase.idle;
  int reconnectAttempt = 0;
  CallEndReason? endReason;
  bool audioOnly = false;

  Timer? _timer;

  bool get canCall =>
      phase == CallPhase.idle ||
      phase == CallPhase.ended ||
      phase == CallPhase.failed;

  bool get canHangUp =>
      phase == CallPhase.connecting ||
      phase == CallPhase.negotiating ||
      phase == CallPhase.connected ||
      phase == CallPhase.reconnecting;

  /// Simulates placing a call: connecting -> negotiating -> connected.
  void placeCall() {
    _timer?.cancel();
    endReason = null;
    audioOnly = false;
    phase = CallPhase.connecting;
    notifyListeners();
    _timer = Timer(const Duration(milliseconds: 250), () {
      phase = CallPhase.negotiating;
      notifyListeners();
      _timer = Timer(const Duration(milliseconds: 250), () {
        phase = CallPhase.connected;
        notifyListeners();
      });
    });
  }

  /// Simulates a graceful local hang-up: ending -> ended.
  void hangUp() {
    _timer?.cancel();
    phase = CallPhase.ending;
    notifyListeners();
    _timer = Timer(const Duration(milliseconds: 200), () {
      phase = CallPhase.ended;
      endReason = CallEndReason.localHangup;
      notifyListeners();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

/// Drives [ChatScreen] over a real [ReliableMessenger].
///
/// Two transports, same messaging stack either way:
/// - Default (no [callChannelPort]): an in-process [LoopbackPort] pair with
///   an auto-replying peer — genuine reliable delivery/ack/de-dup, zero
///   network, so the demo works standalone.
/// - Call mode ([callChannelPort] from [CallSessionHandle.openChatPort]):
///   the messenger rides the live call's own data channel; the remote human
///   is the peer, so there is no local echo side and incoming attachments
///   are reassembled off the wire.
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
        unawaited(peer.send('echo: ${message.text}'));
      });
    }
    _local = ReliableMessenger(localPort, peerId: localSenderId);

    _deliverySub = _local.deliveries.listen((event) {
      final (id, state) = event;
      deliveryStates[id] = state;
      notifyListeners();
    });

    _localSub = _local.incoming.listen((message) {
      if (_localAttachments.offer(message.text)) {
        return; // reassembling; the completed stream emits the bubble
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

  /// Ack outcome per outbound message id ([ChatScreen] reads this to draw
  /// the per-bubble marker); an outbound id absent here is still pending.
  final Map<String, DeliveryState> deliveryStates = {};

  /// Outbound transfer progress per attachment id, 0.0 → 1.0 ([ChatScreen]
  /// draws the bubble's progress bar while < 1.0).
  final Map<String, double> attachmentProgress = {};

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

  /// Picker injected at construction ([pickAttachmentFile] in the app, a
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
    unawaited(_deliverySub.cancel());
    unawaited(_localSub.cancel());
    unawaited(_peerSub?.cancel());
    unawaited(_localAttachmentsSub.cancel());
    unawaited(_local.close());
    unawaited(_peer?.close());
    super.dispose();
  }
}

/// DEV-ONLY: connects to a local dev signaling relay
/// (`server/signaling_server`) for manual real-device testing. Not part of
/// the default demo flow, not called from anywhere in this file's widget
/// tree, and safe to call even with no relay running — failures are caught
/// and returned as `null` instead of throwing.
CallSessionHandle? devConnectToLocalRelay({required String callId}) {
  try {
    return buildWebRtcCallSession(
      endpoint: Uri.parse('wss://localhost:4443'),
      callId: callId,
      role: CallRole.initiator,
    );
  } catch (_) {
    return null;
  }
}
