/// Reference app: a two-tab demo (Call / Chat) that runs standalone, with
/// no server, camera, or network required — every screen is driven by
/// plain state owned by the controllers in `src/`. Real device/network
/// wiring (`buildWebRtcCallSession`) is kept available but only from the
/// clearly-marked dev entry point at the bottom of this file.
library;

import 'dart:async';

import 'package:call_core/call_core.dart';
import 'package:flutter/material.dart';

import 'src/attachment_picker.dart';
import 'src/call_demo_controller.dart';
import 'src/call_screen.dart';
import 'src/call_session.dart';
import 'package:live_captions/live_captions.dart' show ChannelInvite;

import 'src/chat_demo_controller.dart';
import 'src/chat_screen.dart';
import 'src/intelligence/device_bindings.dart';
import 'src/intelligence/foresight_card.dart';
import 'src/intelligence/intelligence_boot.dart';
import 'src/join_channel_sheet.dart';
import 'src/theme.dart';

export 'src/call_demo_controller.dart';
export 'src/chat_demo_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Boot the intelligence circuit before the first frame: both brains
  // restored from disk, fabric place-aware, director watching. The device
  // binding seam supplies the real mesh radio and LLM engine when present;
  // both are null in the demo/gate build, so the app degrades cleanly.
  final intelligence = await bootIntelligence(
    localMeshLane: buildLocalMeshLane(),
    llmEngine: buildLlmEngine(),
  );
  runApp(MyApp(intelligence: intelligence));
}

class MyApp extends StatelessWidget {
  const MyApp({super.key, this.intelligence});

  /// Null only in widget tests that exercise screens in isolation.
  final IntelligenceStack? intelligence;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'VoiceCallKit Reference',
      theme: buildAppTheme(Brightness.light),
      darkTheme: buildAppTheme(Brightness.dark),
      home: HomePage(intelligence: intelligence),
    );
  }
}

/// Root scaffold: a [NavigationBar] switching between the Call and Chat
/// tabs. Owns both tabs' state so the screens themselves stay pure-data.
class HomePage extends StatefulWidget {
  const HomePage({super.key, this.intelligence});

  final IntelligenceStack? intelligence;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _index = 0;

  /// The caption channel the user joined via link/id, shown as a chip in
  /// the caption strip area (full channel session arrives with the STT
  /// engine wiring).
  ChannelInvite? _joinedChannel;
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
        onPlayAudio: _chat.playAudio,
        captions: _chat.captions,
        captionLanguage: 'fa',
      ),
    ];
    return Scaffold(
      appBar: AppBar(
        title: Text(_index == 0 ? 'Call' : 'Chat'),
        actions: [
          IconButton(
            tooltip: 'Join caption channel',
            icon: const Icon(Icons.closed_caption),
            onPressed: () async {
              final invite = await showJoinChannelSheet(context);
              if (invite != null && mounted) {
                setState(() => _joinedChannel = invite);
              }
            },
          ),
        ],
      ),
      body: Column(
        children: [
          if (widget.intelligence != null)
            ForesightCard(director: widget.intelligence!.director),
          if (_joinedChannel != null)
            MaterialBanner(
              leading: const Icon(Icons.closed_caption),
              content: Text(
                'Caption channel ${_joinedChannel!.channelId}'
                '${_joinedChannel!.language == null ? '' : ' · ${_joinedChannel!.language}'}',
              ),
              actions: [
                TextButton(
                  onPressed: () => setState(() => _joinedChannel = null),
                  child: const Text('Leave'),
                ),
              ],
            ),
          Expanded(child: pages[_index]),
        ],
      ),
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
