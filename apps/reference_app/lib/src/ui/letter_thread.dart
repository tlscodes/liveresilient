// The letters as a thread: every delivered record, oldest first — the
// text, a voice label, or the thumbnail itself, from the ledger's own
// bytes — then every letter still parked in the queue, and above them
// the relay's and the door's state from the courier's own fabric. A plain
// list on purpose: ChatScreen speaks the messenger's entries and a letter
// is not one of them.
import 'package:connection_orchestrator/connection_orchestrator.dart'
    show ConnectivitySnapshot, ResilientLaneIds;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../letter_ledger.dart';
import '../letter_queue.dart';
import '../letter_status_ladder.dart';

/// One page over the ledger, the queue and the fabric's last snapshot,
/// pushed from the Chats row. [pending], [lanes] and [ladder] are optional
/// so a host with only a ledger still gets the records.
class LetterThreadPage extends StatelessWidget {
  const LetterThreadPage({
    super.key,
    required this.ledger,
    this.pending,
    this.lanes,
    this.ladder,
  });

  final LetterLedger ledger;
  final ValueListenable<List<QueuedLetter>>? pending;
  final ValueListenable<ConnectivitySnapshot?>? lanes;

  /// Same source the Director's own sentence reads — see
  /// [LetterThread]'s doc comment for why this is a second line, not a
  /// parsed piece of the lane line above it.
  final ValueListenable<LetterLadderStatus?>? ladder;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text(letterConversationTitle)),
    // One rebuild on any of the four sources; an absent source is simply
    // not listened to.
    body: ListenableBuilder(
      listenable: Listenable.merge([ledger.records, pending, lanes, ladder]),
      builder: (context, _) => LetterThread(
        records: ledger.records.value,
        pending: pending?.value ?? const [],
        lanes: lanes?.value,
        ladder: ladder?.value,
      ),
    ),
  );
}

/// One line per lane, as the fabric last saw it: `relay −1.05 down`,
/// `door 0.60 up`. Nothing here probes; a null snapshot says so.
String laneStateLine(ConnectivitySnapshot? s) {
  if (s == null) return 'Lanes not probed yet';
  String name(String id) => switch (id) {
    ResilientLaneIds.txtQuery => 'door',
    'resilient.wss' => 'relay',
    'resilient.https' => 'long-poll',
    _ => id.replaceFirst('resilient.', ''),
  };
  final parts = [
    for (final lane in s.lanes)
      // Dead = the fabric's deadLaneScore (−1.0 − penalty); a live lane
      // with fresh health sits just under 0, e.g. the door at −0.14.
      '${name(lane.id)} ${lane.score.toStringAsFixed(2)} '
          '${lane.eligible && lane.score > -1.0 ? 'up' : 'down'}',
  ];
  final best = s.bestLaneId == null ? 'none' : name(s.bestLaneId!);
  return '${parts.join(' · ')} · mode ${s.mode.name} · best $best';
}

/// The records as bubbles, ours and on the end side, newest at the bottom,
/// then the parked ones, greyed, each saying it waits for the door.
///
/// The rung line under the lane line reads [ladder] directly — the same
/// [LetterLadderStatus] the courier publishes and the Director's own
/// sentence narrates — rather than being parsed out of a status string,
/// so the word on screen here can never drift from the word Director
/// says.
class LetterThread extends StatelessWidget {
  const LetterThread({
    super.key,
    required this.records,
    this.pending = const [],
    this.lanes,
    this.ladder,
  });

  final List<LetterRecord> records;
  final List<QueuedLetter> pending;
  final ConnectivitySnapshot? lanes;
  final LetterLadderStatus? ladder;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView.builder(
      key: const Key('letter-thread'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      itemCount: 1 + records.length + pending.length,
      itemBuilder: (context, index) {
        if (index == 0) {
          final rung = ladder?.rung;
          return Padding(
            key: const Key('letter-thread-lanes'),
            padding: const EdgeInsets.only(bottom: 6),
            child: Column(
              children: [
                Text(
                  laneStateLine(lanes),
                  textAlign: TextAlign.center,
                  style: theme.textTheme.labelSmall,
                ),
                if (rung != null)
                  Text(
                    rung.bannerName,
                    key: const Key('letter-thread-rung'),
                    textAlign: TextAlign.center,
                    style: theme.textTheme.labelSmall,
                  ),
              ],
            ),
          );
        }
        final i = index - 1;
        if (i < records.length) {
          final record = records[i];
          return _bubble(
            theme,
            key: ValueKey('letter-bubble-$i'),
            color: theme.colorScheme.primaryContainer,
            kind: record.kind,
            bytes: record.bytes,
            preview: letterPreview(record),
            foot: record.sessionId == null
                ? 'via ${(record.laneId ?? 'a lane').replaceFirst('resilient.', '')}'
                : 'through the door · session ${record.sessionId}',
          );
        }
        final parked = pending[i - records.length];
        return _bubble(
          theme,
          key: ValueKey('letter-queued-${i - records.length}'),
          color: theme.colorScheme.surfaceContainerHighest,
          kind: parked.kind,
          bytes: parked.bytes,
          preview: letterPreviewOf(parked.kind, parked.bytes, parked.duration),
          foot: 'queued, door down · goes once the door answers',
        );
      },
    );
  }

  Widget _bubble(
    ThemeData theme, {
    required Key key,
    required Color color,
    required String kind,
    required Uint8List bytes,
    required String preview,
    required String foot,
  }) => Align(
    alignment: AlignmentDirectional.centerEnd,
    child: Container(
      key: key,
      margin: const EdgeInsetsDirectional.only(top: 6, start: 48),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (kind == 'photo')
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.memory(
                bytes,
                fit: BoxFit.contain,
                // A photo letter this host cannot draw (AVIF on an older
                // OS) stays a row in the thread instead of an exception.
                errorBuilder: (context, error, stack) => const SizedBox(
                  key: Key('letter-thread-photo-undrawable'),
                  height: 72,
                  width: 72,
                  child: Icon(Icons.image_outlined),
                ),
              ),
            ),
          if (kind == 'voice')
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.mic, size: 18),
                const SizedBox(width: 6),
                Text(preview),
              ],
            ),
          if (kind != 'photo' && kind != 'voice') Text(preview),
          const SizedBox(height: 4),
          Text(foot, style: theme.textTheme.labelSmall),
        ],
      ),
    ),
  );
}
