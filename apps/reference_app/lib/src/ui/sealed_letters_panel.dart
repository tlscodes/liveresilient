// Sealed letters on the screen: who this install can write to, what it
// wrote and where each letter is, and what was opened here. The same panel
// on every platform — and on the rig peer — so "the letter was read in the
// app" means the same thing everywhere.
//
// Nothing here spins. A letter that has not been opened is in the queue,
// and the line under it says why: the relay could not be reached, or the
// box is on the relay and nobody has opened it yet.
//
// Showing this panel is "the screen was opened": the service looks at the
// shelves often for a while afterwards, and again when the app comes back
// into view.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:messaging/messaging.dart' show Attachment, MediaKind;

import '../peer_identity.dart';
import '../sealed/sealed_content.dart';
import '../sealed/sealed_letter_service.dart';
import '../theme.dart';

String _short(String install) =>
    install.length <= 8 ? install : install.substring(0, 8);

String _clock(DateTime at) {
  final local = at.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
}

class SealedLettersPanel extends StatefulWidget {
  const SealedLettersPanel({
    super.key,
    required this.service,
    required this.identity,
    this.pickAttachment,
  });

  final SealedLetterService service;
  final AppIdentity identity;

  /// Lets the person choose a photo, a recording or a video to seal. Null
  /// hides the attach button (a host with no file picker).
  final Future<Attachment?> Function()? pickAttachment;

  @override
  State<SealedLettersPanel> createState() => _SealedLettersPanelState();
}

class _SealedLettersPanelState extends State<SealedLettersPanel>
    with WidgetsBindingObserver {
  final TextEditingController _text = TextEditingController();
  List<String> _peers = const [];
  String? _to;
  String? _error;
  bool _busy = false;
  AppLifecycleState? _was;

  @override
  void initState() {
    super.initState();
    widget.service.inbox.addListener(_changed);
    widget.service.outbox.addListener(_changed);
    widget.service.relay.addListener(_changed);
    lastPeerSighting.addListener(_reloadPeers);
    WidgetsBinding.instance.addObserver(this);
    widget.service.touch();
    _reloadPeers();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.service.inbox.removeListener(_changed);
    widget.service.outbox.removeListener(_changed);
    widget.service.relay.removeListener(_changed);
    lastPeerSighting.removeListener(_reloadPeers);
    _text.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Coming back into view is the screen being opened again. Losing and
    // regaining focus while it stays in view is not.
    final wasOutOfView =
        _was == AppLifecycleState.hidden ||
        _was == AppLifecycleState.paused ||
        _was == AppLifecycleState.detached;
    final inView =
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.resumed;
    if (wasOutOfView && inView) widget.service.touch();
    _was = state;
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  /// Everyone pinned can be written to; a call that just pinned someone
  /// makes them appear here.
  void _reloadPeers() {
    unawaited(() async {
      final peers = await widget.identity.pinnedInstalls();
      if (!mounted) return;
      setState(() {
        _peers = peers;
        final recent = lastPeerSighting.value?.peerInstall;
        _to = peers.contains(_to)
            ? _to
            : peers.contains(recent)
            ? recent
            : (peers.isEmpty ? null : peers.first);
      });
    }());
  }

  /// Runs one send and turns what can go wrong into a sentence. The busy
  /// flag only guards against a double tap; it is cleared the moment the
  /// letter is queued, which is at once — nothing here waits on a network.
  Future<void> _guarded(Future<void> Function(String to) send) async {
    final to = _to;
    if (to == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await send(to);
    } on NotPinnedError {
      _error = 'No pinned key for that install — call them once first.';
    } on ArgumentError {
      _error = 'That is too large for one sealed letter (about 3 MB).';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _send() async {
    final text = _text.text.trim();
    if (text.isEmpty) return;
    await _guarded((to) async {
      await widget.service.send(
        toInstall: to,
        body: Uint8List.fromList(utf8.encode(text)),
      );
      _text.clear();
    });
  }

  Future<void> _attach() async {
    final pick = widget.pickAttachment;
    if (pick == null) return;
    final chosen = await pick();
    if (chosen == null) return;
    final type = chosen.contentType;
    await _guarded(
      (to) => widget.service.sendMedia(
        toInstall: to,
        kind: switch (chosen.kind) {
          MediaKind.image => SealedMediaKind.photo,
          MediaKind.video => SealedMediaKind.video,
          MediaKind.file =>
            type.startsWith('audio/')
                ? SealedMediaKind.voice
                : SealedMediaKind.file,
        },
        contentType: type,
        bytes: Uint8List.fromList(chosen.bytes),
        caption: _text.text.trim(),
      ),
    );
    if (_error == null) _text.clear();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall;
    final sent = widget.service.outbox.value;
    final received = widget.service.inbox.value;
    final relay = widget.service.relay.value;
    final now = DateTime.now();
    if (_peers.isEmpty && sent.isEmpty && received.isEmpty) {
      // Nobody pinned yet and nothing to show: the panel stays out of the
      // way until the first call makes a correspondent.
      return const SizedBox.shrink();
    }
    return Card(
      key: const Key('sealed-panel'),
      margin: const EdgeInsets.all(Spacing.s12),
      child: Padding(
        padding: const EdgeInsets.all(Spacing.s12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.mark_email_read_outlined, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Sealed letters',
                    style: theme.textTheme.titleSmall,
                  ),
                ),
                Text(
                  switch (relay) {
                    SealedRelayState.unknown => 'relay not asked yet',
                    SealedRelayState.reachable => 'relay reachable',
                    SealedRelayState.unreachable =>
                      'relay unreachable — letters wait',
                    SealedRelayState.spent =>
                      "today's requests are used up — letters wait",
                  },
                  key: const Key('sealed-relay'),
                  style: small,
                ),
              ],
            ),
            if (_peers.length > 1)
              DropdownButton<String>(
                key: const Key('sealed-recipient'),
                isExpanded: true,
                value: _to,
                items: [
                  for (final peer in _peers)
                    DropdownMenuItem(
                      value: peer,
                      child: Text('to ${_short(peer)}…'),
                    ),
                ],
                onChanged: (value) => setState(() => _to = value),
              )
            else if (_to != null)
              Padding(
                padding: const EdgeInsets.only(top: Spacing.s4),
                child: Text(
                  'to ${_short(_to!)}… — locked to the key you pinned',
                  key: const Key('sealed-recipient'),
                  style: small,
                ),
              ),
            if (_to != null)
              Row(
                children: [
                  if (widget.pickAttachment != null)
                    IconButton(
                      key: const Key('sealed-attach'),
                      tooltip: 'Seal a photo, a recording or a video',
                      onPressed: _busy ? null : () => unawaited(_attach()),
                      icon: const Icon(Icons.attach_file),
                    ),
                  Expanded(
                    child: TextField(
                      key: const Key('sealed-compose'),
                      controller: _text,
                      minLines: 1,
                      maxLines: 3,
                      decoration: const InputDecoration(
                        hintText: 'Write a sealed letter',
                        isDense: true,
                      ),
                      onSubmitted: (_) => unawaited(_send()),
                    ),
                  ),
                  IconButton(
                    key: const Key('sealed-send'),
                    tooltip: 'Seal and send',
                    onPressed: _busy ? null : () => unawaited(_send()),
                    icon: const Icon(Icons.lock_outline),
                  ),
                ],
              ),
            if (_error != null)
              Text(
                _error!,
                key: const Key('sealed-error'),
                style: small?.copyWith(color: theme.colorScheme.error),
              ),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 220),
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final letter in received.reversed)
                    ListTile(
                      key: Key('sealed-received-${letter.id}'),
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                        letter.verified
                            ? Icons.verified_user
                            : Icons.lock_outline,
                        size: 18,
                      ),
                      title: _ReceivedBody(letter: letter),
                      subtitle: Text(
                        'from ${_short(letter.from)}… · '
                        '${letter.verified ? 'verified' : 'not yet verified'} '
                        '· opened here ${_clock(letter.receivedAt)}',
                      ),
                    ),
                  for (final letter in sent.reversed)
                    ListTile(
                      key: Key('sealed-sent-${letter.id}'),
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(switch (letter.state) {
                        SealedSentState.opened => Icons.done_all,
                        SealedSentState.shelved => Icons.schedule,
                        SealedSentState.waiting => Icons.cloud_off,
                      }, size: 18),
                      title: Text(letter.text),
                      subtitle: Text(
                        'to ${_short(letter.to)}… · ${letter.describe(now)}',
                        key: Key('sealed-state-${letter.id}'),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// What opened: the text, the photo itself, or a plain line naming a voice
/// note or a video with its size and length. Playing audio and video from
/// here is not built; they are shown as what they are.
class _ReceivedBody extends StatelessWidget {
  const _ReceivedBody({required this.letter});

  final SealedReceived letter;

  @override
  Widget build(BuildContext context) {
    final media = letter.content.media;
    final bytes = letter.media;
    if (media == null || bytes == null) return Text(letter.text);
    final line = Text(letter.content.summary);
    if (media.kind != SealedMediaKind.photo) {
      return Row(
        children: [
          Icon(switch (media.kind) {
            SealedMediaKind.voice => Icons.mic,
            SealedMediaKind.video => Icons.videocam,
            _ => Icons.insert_drive_file,
          }, size: 18),
          const SizedBox(width: 6),
          Expanded(child: line),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(AppRadius.r12),
          child: Image.memory(
            bytes,
            key: Key('sealed-photo-${letter.id}'),
            height: 96,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            // A format this platform cannot draw is still a received,
            // verified photo; say so instead of showing a broken image.
            errorBuilder: (_, _, _) => const Text(
              'photo received — this device cannot draw its format',
            ),
          ),
        ),
        line,
      ],
    );
  }
}
