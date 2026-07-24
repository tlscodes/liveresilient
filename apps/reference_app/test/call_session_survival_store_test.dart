/// Proves the survival-mode fallback queue that [buildWebRtcCallSession]
/// wires up is disk-backed, not in-memory: a bundle offered before the
/// process (here, simulated by disposing the session and its queue) "dies"
/// is still pending — in the same delivery order — once a fresh session is
/// built over the same storage directory and call id.
library;

import 'dart:io';

import 'package:call_core/call_core.dart';
import 'package:device_link/device_link.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reference_app/src/call_session.dart';

void main() {
  test(
    'restart survival: bundle offered before "process death" is still '
    'pending, in order, after the queue is rebuilt on the same file',
    () async {
      final dir = Directory.systemTemp.createTempSync('survival_store_test');
      addTearDown(() => dir.deleteSync(recursive: true));
      const callId = 'restart-survival-call';

      final first = buildWebRtcCallSession(
        endpoint: Uri.parse('wss://localhost:0/'),
        callId: callId,
        role: CallRole.initiator,
        storageDirFactory: () => dir,
      );
      final queue = first.survivalFallbackQueue;
      expect(queue, isNotNull);

      final now = DateTime.now().millisecondsSinceEpoch;
      queue!.offer(
        DtnBundle(
          id: 'clip-1',
          payload: const [1, 2, 3],
          priority: MeshMessagePriority.presence,
          createdAtMs: now,
          lifetimeMs: 60000,
        ),
        nowMs: now,
      );
      queue.offer(
        DtnBundle(
          id: 'clip-2',
          payload: const [4, 5, 6],
          priority: MeshMessagePriority.presence,
          createdAtMs: now + 1,
          lifetimeMs: 60000,
        ),
        nowMs: now + 1,
      );
      expect(queue.pendingCount, 2);

      // "Process death": drop every in-memory object without a clean
      // dispose (a real crash never calls dispose either).
      await first.dispose();

      final second = buildWebRtcCallSession(
        endpoint: Uri.parse('wss://localhost:0/'),
        callId: callId,
        role: CallRole.initiator,
        storageDirFactory: () => dir,
      );
      final restored = second.survivalFallbackQueue!;
      final pending = restored.pendingInDeliveryOrder(
        DateTime.now().millisecondsSinceEpoch,
      );
      expect(pending.map((b) => b.id), <String>['clip-1', 'clip-2']);
      await second.dispose();
    },
  );

  test('no storage dir supplied: falls back to a durable temp-dir file and '
      'still survives a rebuild', () async {
    const callId = 'restart-survival-default-dir';
    final first = buildWebRtcCallSession(
      endpoint: Uri.parse('wss://localhost:0/'),
      callId: callId,
      role: CallRole.receiver,
    );
    final queue = first.survivalFallbackQueue!;
    final now = DateTime.now().millisecondsSinceEpoch;
    queue.offer(
      DtnBundle(
        id: 'clip-default',
        payload: const [9],
        priority: MeshMessagePriority.presence,
        createdAtMs: now,
        lifetimeMs: 60000,
      ),
      nowMs: now,
    );
    await first.dispose();

    final second = buildWebRtcCallSession(
      endpoint: Uri.parse('wss://localhost:0/'),
      callId: callId,
      role: CallRole.receiver,
    );
    final restored = second.survivalFallbackQueue!;
    expect(restored.pendingCount, 1);
    await second.dispose();
  });
}
