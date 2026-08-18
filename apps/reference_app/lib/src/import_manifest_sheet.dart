/// The screen that makes the out-of-band manifest real.
///
/// WHY THIS EXISTS. `OobManifestImport` and `CompactManifestCode` break the
/// bootstrap circularity — a device with no reachable config origin can learn
/// where to connect from a code someone photographs, prints, or reads aloud.
/// But a capability nobody can invoke is not a capability. Until this sheet
/// existed the import path had no caller anywhere in the app, which is the same
/// ORPHAN pattern the audit found three times already.
///
/// DELIBERATELY NO CAMERA. The app declares in `main.dart` that it runs with no
/// camera, and adding a QR/barcode dependency to the bootstrap path — the one
/// path that must work when everything else has failed — buys convenience at
/// the cost of another platform surface that can break, and a permission prompt
/// on the least explicable screen in the product. Paste and file cover every
/// delivery a person can actually perform: a photo read by any scanner app and
/// pasted here, a string sent through another channel, a file sideloaded. When
/// a camera is added it becomes a third button on this sheet and nothing else
/// changes, because the trust decision does not live here.
///
/// WHAT THIS SHEET IS NOT ALLOWED TO DO: decide. It hands bytes to
/// [OobManifestImport] and displays the verdict. Every rule that matters —
/// pinned keys, validity window, revision monotonicity — belongs to the
/// verifier, identical to the network path. A screen that could relax any of
/// them would be the weakest link in the whole design.
library;


import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:signed_config/signed_config.dart';

import 'theme.dart';

/// Shows the sheet; completes with an accepted manifest, or null if the user
/// cancelled or nothing verified.
Future<EndpointManifest?> showImportManifestSheet(
  BuildContext context, {
  required OobManifestImport import,
}) {
  return showModalBottomSheet<EndpointManifest>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => ImportManifestSheet(import: import),
  );
}

class ImportManifestSheet extends StatefulWidget {
  const ImportManifestSheet({super.key, required this.import});

  final OobManifestImport import;

  @override
  State<ImportManifestSheet> createState() => _ImportManifestSheetState();
}

class _ImportManifestSheetState extends State<ImportManifestSheet> {
  final _controller = TextEditingController();
  OobImportResult? _result;
  bool _busy = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Set when the import threw rather than returning a verdict — a defect, not
  /// a rejection, and shown as such.
  String? _crash;

  /// EVERY path must clear [_busy].
  ///
  /// The first version had no try/catch. `OobManifestImport.importBytes`
  /// catches only `FormatException`, so anything else — a `TypeError` from a
  /// JSON document of the wrong shape, a base64 `ArgumentError` — escaped, the
  /// `setState` that clears `_busy` never ran, and all three buttons stayed
  /// disabled forever with no message. The sheet bricked itself, on the screen
  /// that exists for when nothing else in the app works.
  Future<void> _run(Future<OobImportResult> Function() action) async {
    setState(() {
      _busy = true;
      _crash = null;
    });
    OobImportResult? result;
    String? crash;
    try {
      result = await action();
    } on Object catch (e) {
      crash = '$e';
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _result = result;
          _crash = crash;
        });
      }
    }
  }

  Future<void> _importTyped() =>
      _run(() => widget.import.importText(_controller.text));

  Future<void> _importClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text ?? '';
    if (text.trim().isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Clipboard is empty')));
      return;
    }
    _controller.text = text;
    await _importTyped();
  }

  /// A manifest is kilobytes. Reading whatever the user picked without a bound
  /// is an out-of-memory crash one mis-tap away, on a phone, on the recovery
  /// screen.
  static const int _maxFileBytes = 256 * 1024;

  Future<void> _importFile() async {
    const group = XTypeGroup(label: 'manifest', extensions: ['json', 'txt']);
    // File picking and reading are inside _run too: openFile can throw
    // (permission denied, the file vanished) and an unguarded throw here is
    // the same deadlock the _run comment describes.
    await _run(() async {
      final file = await openFile(acceptedTypeGroups: const [group]);
      if (file == null) {
        return const OobImportResult(
          source: OobManifestSource.file,
          verification: null,
        );
      }
      final size = await file.length();
      if (size > _maxFileBytes) {
        throw StateError(
          'that file is ${(size / 1024).round()} KB; a manifest is a few KB. '
          'Pick the signed manifest, not the media.',
        );
      }
      final bytes = await file.readAsBytes();
      return widget.import.importBytes(
        bytes,
        source: OobManifestSource.file,
      );
    });
  }

  /// Colour follows meaning, not severity: a code that would not READ is a
  /// different problem from a code that would not VERIFY, and the recoveries
  /// are opposite — "read it again" versus "distrust whoever gave it to you".
  (IconData, Color, String) _verdict(ThemeData theme, OobImportResult r) {
    if (r.decodeError != null) {
      return (
        Icons.text_snippet_outlined,
        theme.colorScheme.tertiary,
        'Could not read this. Check for a missed or extra character, '
            'then try again — nothing was trusted or stored.',
      );
    }
    final v = r.verification;
    if (v is ManifestAccepted) {
      return (
        Icons.verified_outlined,
        theme.colorScheme.primary,
        'Verified: revision ${v.manifest.revision}, '
            '${v.manifest.iceServers.length} servers. '
            'Signed by a key this app already trusts.',
      );
    }
    if (v is ManifestRejected) {
      return (
        Icons.gpp_bad_outlined,
        theme.colorScheme.error,
        switch (v.reason) {
          ManifestRejection.badSignature ||
          ManifestRejection.malformedSignature =>
            'The signature does not match. This was altered, or it came '
                'from someone who cannot sign for this app. Do not use it.',
          ManifestRejection.unknownSigningKey ||
          ManifestRejection.revokedSigningKey =>
            'Signed by a key this app does not trust.',
          ManifestRejection.rollback =>
            'Older than the settings this device already has, so it was '
                'refused. That is rollback protection working.',
          ManifestRejection.expired ||
          ManifestRejection.notYetValid =>
            'Outside its validity window — ask for a current one.',
          ManifestRejection.unsupportedAlgorithm =>
            'Made for a newer version of this app. Update, then retry.',
          ManifestRejection.malformed =>
            'Readable, but not a manifest.',
        },
      );
    }
    return (Icons.help_outline, theme.colorScheme.outline, '');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final result = _result;
    final accepted = result?.manifest;

    return Padding(
      padding: EdgeInsets.only(
        left: Spacing.s16,
        right: Spacing.s16,
        top: Spacing.s8,
        bottom: MediaQuery.of(context).viewInsets.bottom + Spacing.s16,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Import connection settings', style: theme.textTheme.titleLarge),
            const SizedBox(height: Spacing.s8),
            Text(
              'For when this device cannot reach the network that would '
              'normally provide them. Paste a code, or open a file you were '
              'given. It is checked exactly as strictly as one downloaded '
              'over the network — a tampered code is refused, never trusted.',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: Spacing.s16),
            TextField(
              controller: _controller,
              maxLines: 4,
              minLines: 2,
              autofocus: true,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: 'Code or signed text',
                hintText: 'CFM1-XXXXX-XXXXX-…',
              ),
            ),
            const SizedBox(height: Spacing.s12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _busy ? null : _importClipboard,
                    icon: const Icon(Icons.content_paste),
                    label: const Text('Paste'),
                  ),
                ),
                const SizedBox(width: Spacing.s8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _busy ? null : _importFile,
                    icon: const Icon(Icons.folder_open),
                    label: const Text('Open file'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: Spacing.s12),
            FilledButton.icon(
              onPressed: _busy ? null : _importTyped,
              icon: const Icon(Icons.shield_outlined),
              label: const Text('Check this code'),
            ),
            if (_crash != null) ...[
              const SizedBox(height: Spacing.s16),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.bug_report_outlined, color: theme.colorScheme.error),
                  const SizedBox(width: Spacing.s8),
                  Expanded(
                    child: Text(
                      // Named as a fault in the app, not in the code the user
                      // was given: this is the third failure class, distinct
                      // from "could not read" and from "do not trust".
                      'Something went wrong reading that — this is a fault in '
                      'the app, not in your code. Nothing was trusted or '
                      'stored. Details: $_crash',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.error,
                      ),
                    ),
                  ),
                ],
              ),
            ],
            if (result != null) ...[
              const SizedBox(height: Spacing.s16),
              Builder(
                builder: (context) {
                  final (icon, colour, message) = _verdict(theme, result);
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(icon, color: colour),
                      const SizedBox(width: Spacing.s8),
                      Expanded(
                        child: Text(
                          message,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: colour,
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ],
            if (accepted != null) ...[
              const SizedBox(height: Spacing.s16),
              FilledButton.icon(
                onPressed: () => Navigator.of(context).pop(accepted),
                icon: const Icon(Icons.download_done),
                label: const Text('Use these settings'),
              ),
            ],
            const SizedBox(height: Spacing.s8),
          ],
        ),
      ),
    );
  }
}
