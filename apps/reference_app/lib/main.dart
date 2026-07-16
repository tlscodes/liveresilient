/// VoiceCallKit v2 reference app (macOS desktop).
///
/// Single screen driving one call session end to end: signaling endpoint +
/// call id fields, invite/accept/hangup, and a live status line fed by
/// `call_core`'s [CallController] states.
library;

import 'dart:async';

import 'package:call_core/call_core.dart';
import 'package:flutter/material.dart';

import 'src/call_session.dart';

void main() {
  runApp(const ReferenceApp());
}

class ReferenceApp extends StatelessWidget {
  const ReferenceApp({super.key, this.sessionBuilder = buildWebRtcCallSession});

  /// Injectable so widget tests swap the real WSS/WebRTC stack for fakes.
  final CallSessionBuilder sessionBuilder;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'VoiceCallKit Reference',
      theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
      home: CallScreen(sessionBuilder: sessionBuilder),
    );
  }
}

class CallScreen extends StatefulWidget {
  const CallScreen({super.key, required this.sessionBuilder});

  final CallSessionBuilder sessionBuilder;

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  final _endpointController = TextEditingController(
    text: 'wss://localhost:8443',
  );
  final _callIdController = TextEditingController(text: 'call-1');

  CallSessionHandle? _session;
  StreamSubscription<CallState>? _statesSubscription;
  String _status = 'idle';
  bool _busy = false;

  bool get _callActive => _session != null;

  @override
  void dispose() {
    _statesSubscription?.cancel();
    final session = _session;
    if (session != null) {
      unawaited(session.dispose());
    }
    _endpointController.dispose();
    _callIdController.dispose();
    super.dispose();
  }

  Future<void> _startCall(CallRole role) async {
    if (_callActive || _busy) return;
    final endpoint = Uri.tryParse(_endpointController.text.trim());
    final callId = _callIdController.text.trim();
    if (endpoint == null ||
        !(endpoint.scheme == 'wss' || endpoint.scheme == 'ws') ||
        callId.isEmpty) {
      setState(() => _status = 'invalid endpoint or call id');
      return;
    }

    setState(() {
      _busy = true;
      _status = 'starting (${role.name})...';
    });

    final session = widget.sessionBuilder(
      endpoint: endpoint,
      callId: callId,
      role: role,
    );
    _session = session;
    _statesSubscription = session.controller.states.listen(_onState);
    unawaited(
      session.controller.done
          .then((state) => _onDone(session, state))
          .catchError((Object error) => _onDone(session, null, error: error)),
    );

    try {
      await session.controller.start();
      if (mounted) setState(() => _busy = false);
    } catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _status = 'start failed: $error';
        });
      }
      await _teardown(session);
    }
  }

  Future<void> _hangUp() async {
    final session = _session;
    if (session == null || _busy) return;
    setState(() => _busy = true);
    try {
      await session.controller.hangUp();
    } catch (_) {
      // Terminal cleanup happens in _onDone either way.
    }
    if (mounted) setState(() => _busy = false);
  }

  void _onState(CallState state) {
    if (!mounted) return;
    setState(() => _status = _describe(state));
  }

  Future<void> _onDone(
    CallSessionHandle session,
    CallState? state, {
    Object? error,
  }) async {
    if (state != null && mounted) {
      setState(() => _status = _describe(state));
    } else if (error != null && mounted) {
      setState(() => _status = 'call error: $error');
    }
    await _teardown(session);
  }

  Future<void> _teardown(CallSessionHandle session) async {
    if (!identical(_session, session)) return;
    await _statesSubscription?.cancel();
    _statesSubscription = null;
    _session = null;
    await session.dispose();
    if (mounted) setState(() {});
  }

  static String _describe(CallState state) {
    final buffer = StringBuffer(state.phase.name);
    if (state.phase == CallPhase.reconnecting) {
      buffer.write(' (attempt ${state.reconnectAttempt})');
    }
    final reason = state.endReason;
    if (reason != null) {
      buffer.write(' (${reason.name})');
    }
    return buffer.toString();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('VoiceCallKit Reference')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _endpointController,
              enabled: !_callActive,
              decoration: const InputDecoration(
                labelText: 'Signaling endpoint (wss://...)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _callIdController,
              enabled: !_callActive,
              decoration: const InputDecoration(
                labelText: 'Call ID',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 24),
            Row(
              children: [
                FilledButton.icon(
                  onPressed: _callActive || _busy
                      ? null
                      : () => _startCall(CallRole.initiator),
                  icon: const Icon(Icons.call),
                  label: const Text('Invite'),
                ),
                const SizedBox(width: 12),
                FilledButton.tonalIcon(
                  onPressed: _callActive || _busy
                      ? null
                      : () => _startCall(CallRole.receiver),
                  icon: const Icon(Icons.call_received),
                  label: const Text('Accept'),
                ),
                const SizedBox(width: 12),
                OutlinedButton.icon(
                  onPressed: _callActive && !_busy ? _hangUp : null,
                  icon: const Icon(Icons.call_end),
                  label: const Text('Hang up'),
                ),
              ],
            ),
            const SizedBox(height: 24),
            Text(
              'Status: $_status',
              key: const ValueKey('call-status'),
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ],
        ),
      ),
    );
  }
}
