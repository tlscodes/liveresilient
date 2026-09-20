// The letters as a thread: every delivered record, oldest first — the
// text, a voice label, or the thumbnail itself, from the ledger's own
// bytes. A plain list on purpose: ChatScreen speaks the messenger's
// entries and a letter is not one of them.
import 'package:flutter/material.dart';

import '../letter_ledger.dart';

/// One page over the ledger, pushed from the Chats row.
class LetterThreadPage extends StatelessWidget {
  const LetterThreadPage({super.key, required this.ledger});

  final LetterLedger ledger;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text(letterConversationTitle)),
    body: ValueListenableBuilder<List<LetterRecord>>(
      valueListenable: ledger.records,
      builder: (context, records, _) => LetterThread(records: records),
    ),
  );
}

/// The records as bubbles, ours and on the end side, newest at the bottom.
class LetterThread extends StatelessWidget {
  const LetterThread({super.key, required this.records});

  final List<LetterRecord> records;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView.builder(
      key: const Key('letter-thread'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      itemCount: records.length,
      itemBuilder: (context, index) {
        final record = records[index];
        return Align(
          alignment: AlignmentDirectional.centerEnd,
          child: Container(
            key: ValueKey('letter-bubble-$index'),
            margin: const EdgeInsetsDirectional.only(top: 6, start: 48),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: theme.colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (record.kind == 'photo')
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.memory(record.bytes, fit: BoxFit.contain),
                  ),
                if (record.kind == 'voice')
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.mic, size: 18),
                      const SizedBox(width: 6),
                      Text(letterPreview(record)),
                    ],
                  ),
                if (record.kind != 'photo' && record.kind != 'voice')
                  Text(letterPreview(record)),
                const SizedBox(height: 4),
                Text(
                  record.sessionId == null
                      ? 'via ${(record.laneId ?? 'a lane').replaceFirst('resilient.', '')}'
                      : 'through the door · session ${record.sessionId}',
                  style: theme.textTheme.labelSmall,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
