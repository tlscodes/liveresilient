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
import 'src/chat_demo_controller.dart';
import 'src/chat_screen.dart';
import 'src/theme.dart';

export 'src/call_demo_controller.dart';
export 'src/chat_demo_controller.dart';

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
        onPlayAudio: _chat.playAudio,
        captions: _chat.captions,
        captionLanguage: 'fa',
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
