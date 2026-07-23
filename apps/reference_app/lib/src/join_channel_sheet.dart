/// Join-a-caption-channel bottom sheet: one field that accepts everything
/// the invite parser does — a bare channel id (`123456`), the app link
/// (`vck://captions/...`), or a web link (`https://.../c/...`) — with live
/// validation and a language-aware confirmation. The modern replacement
/// for the old login-screen "type the 6-digit code" flow.
library;

import 'package:flutter/material.dart';
import 'package:live_captions/live_captions.dart';

import 'theme.dart';

/// Shows the sheet; completes with the parsed invite or null on cancel.
Future<ChannelInvite?> showJoinChannelSheet(BuildContext context) {
  return showModalBottomSheet<ChannelInvite>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => const JoinChannelSheet(),
  );
}

class JoinChannelSheet extends StatefulWidget {
  const JoinChannelSheet({super.key});

  @override
  State<JoinChannelSheet> createState() => _JoinChannelSheetState();
}

class _JoinChannelSheetState extends State<JoinChannelSheet> {
  final _controller = TextEditingController();
  ChannelInvite? _invite;
  bool _touched = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    setState(() {
      _touched = value.trim().isNotEmpty;
      _invite = ChannelInvite.parse(value);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final invite = _invite;
    return Padding(
      padding: EdgeInsets.only(
        left: Spacing.s16,
        right: Spacing.s16,
        top: Spacing.s8,
        bottom: MediaQuery.of(context).viewInsets.bottom + Spacing.s16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Join a caption channel', style: theme.textTheme.titleLarge),
          const SizedBox(height: Spacing.s8),
          Text(
            'Paste an invite link or type a channel ID.',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: Spacing.s16),
          TextField(
            controller: _controller,
            autofocus: true,
            onChanged: _onChanged,
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              labelText: 'Invite link or channel ID',
              hintText: '123456 · vck://captions/… · https://…/c/…',
              errorText: _touched && invite == null
                  ? 'Not a valid channel ID or invite link'
                  : null,
              suffixIcon: invite == null
                  ? null
                  : const Icon(Icons.check_circle_outline),
            ),
          ),
          if (invite != null) ...[
            const SizedBox(height: Spacing.s12),
            Row(
              children: [
                Chip(
                  avatar: const Icon(Icons.tag, size: 18),
                  label: Text(invite.channelId),
                ),
                if (invite.language != null) ...[
                  const SizedBox(width: Spacing.s8),
                  Chip(
                    avatar: const Icon(Icons.translate, size: 18),
                    label: Text('Captions in ${invite.language}'),
                  ),
                ],
              ],
            ),
          ],
          const SizedBox(height: Spacing.s16),
          FilledButton.icon(
            onPressed: invite == null
                ? null
                : () => Navigator.of(context).pop(invite),
            icon: const Icon(Icons.login),
            label: const Text('Join channel'),
          ),
        ],
      ),
    );
  }
}
