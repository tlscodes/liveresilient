// Sealed letters on the screen: who this install can write to, what it
// wrote and whether each was opened, and what was opened here. The same
// panel on every platform — and on the rig peer — so "the letter was read
// in the app" means the same thing everywhere.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../theme.dart';
import '../peer_identity.dart';
import '../sealed/sealed_letters.dart';

String _short(String install) =>
    install.length <= 8 ? install : install.substring(0, 8);

class SealedLettersPanel extends StatefulWidget {
  const SealedLettersPanel({
    super.key,
    required this.service,
    required this.identity,
  });

  final SealedLetterService service;
  final AppIdentity identity;

  @override
  State<SealedLettersPanel> createState() => _SealedLettersPanelState();
}

class _SealedLettersPanelState extends State<SealedLettersPanel> {
  final TextEditingController _text = TextEditingController();
  List<String> _peers = const [];
  String? _to;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    widget.service.inbox.addListener(_changed);
    widget.service.outbox.addListener(_changed);
    widget.service.doorUp.addListener(_changed);
    lastPeerSighting.addListener(_reloadPeers);
    _reloadPeers();
  }

  @override
  void dispose() {
    widget.service.inbox.removeListener(_changed);
    widget.service.outbox.removeListener(_changed);
    widget.service.doorUp.removeListener(_changed);
    lastPeerSighting.removeListener(_reloadPeers);
    _text.dispose();
    super.dispose();
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

  Future<void> _send() async {
    final to = _to;
    final text = _text.text.trim();
    if (to == null || text.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.service.send(
        toInstall: to,
        body: Uint8List.fromList(utf8.encode(text)),
      );
      _text.clear();
    } on NotPinnedError {
      _error = 'No pinned key for that install — call them once first.';
    } on ArgumentError {
      _error = 'That is too long for one sealed letter.';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall;
    final sent = widget.service.outbox.value;
    final received = widget.service.inbox.value;
    final door = widget.service.doorUp.value;
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
                  switch (door) {
                    null => 'mailbox not read yet',
                    true => 'mailbox reachable',
                    false => 'mailbox unreachable — letters wait',
                  },
                  key: const Key('sealed-door'),
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
              constraints: const BoxConstraints(maxHeight: 180),
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
                      title: Text(letter.text),
                      subtitle: Text(
                        'from ${_short(letter.from)}… · '
                        '${letter.verified ? 'verified' : 'not yet verified'} '
                        '· opened here',
                      ),
                    ),
                  for (final letter in sent.reversed)
                    ListTile(
                      key: Key('sealed-sent-${letter.id}'),
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                        letter.delivered ? Icons.done_all : Icons.schedule,
                        size: 18,
                      ),
                      title: Text(letter.text),
                      subtitle: Text(
                        'to ${_short(letter.to)}… · '
                        '${letter.delivered ? 'opened by them' : 'waiting — put in their mailbox ${letter.attempts}×'}',
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
