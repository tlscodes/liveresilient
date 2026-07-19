/// ChatDemoController in call mode: the same messaging stack the loopback
/// demo uses, but riding a caller-supplied [DataChannelPort] (in production,
/// the live call's data channel via [CallSessionHandle.openChatPort]). The
/// remote human is the peer — no echo side, and incoming attachments are
/// reassembled off the wire into chat entries.
library;

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:live_captions/live_captions.dart';
import 'package:messaging/messaging.dart';
import 'package:reference_app/main.dart';
import 'package:reference_app/src/loopback_port.dart';

/// Drops the first [_toDrop] outbound frames, then forwards normally —
/// simulates a transiently dead channel so a send stays pending until the
/// app's periodic retry driver retransmits it.
class _DroppingPort implements DataChannelPort {
  _DroppingPort(this._inner, {required int drop}) : _toDrop = drop;

  final DataChannelPort _inner;
  int _toDrop;

  @override
  Stream<List<int>> get inbound => _inner.inbound;

  @override
  Future<void> send(List<int> frame) async {
    if (_toDrop > 0) {
      _toDrop--;
      return;
    }
    await _inner.send(frame);
  }

  @override
  Future<void> close() => _inner.close();
}

void main() {
  test('typed text reaches the remote peer over the injected call port, '
      'and the ack drains pending', () async {
    final (callPort, remotePort) = pairLoopbackPorts();
    final controller = ChatDemoController(callChannelPort: callPort);
    final remoteHuman = ReliableMessenger(remotePort, peerId: 'remote');
    final remoteGot = <ChatMessage>[];
    remoteHuman.incoming.listen(remoteGot.add);

    await controller.sendText('سلام از داخل تماس');
    await pumpEventQueue();

    expect(remoteGot, hasLength(1));
    expect(remoteGot.single.text, 'سلام از داخل تماس');

    await remoteHuman.close();
    controller.dispose();
  });

  test(
    'remote text lands in entries; no echo peer exists in call mode',
    () async {
      final (callPort, remotePort) = pairLoopbackPorts();
      final controller = ChatDemoController(callChannelPort: callPort);
      final remoteHuman = ReliableMessenger(remotePort, peerId: 'remote');
      final remoteGot = <ChatMessage>[];
      remoteHuman.incoming.listen(remoteGot.add);

      await remoteHuman.send('پیام از آن سوی تماس');
      await pumpEventQueue();

      expect(controller.entries, hasLength(1));
      expect(controller.entries.single.message.text, 'پیام از آن سوی تماس');
      // Call mode must NOT auto-reply — the remote human is the peer.
      expect(remoteGot, isEmpty);

      await remoteHuman.close();
      controller.dispose();
    },
  );

  test('a chunked attachment from the remote side reassembles into an '
      'attachment entry', () async {
    final (callPort, remotePort) = pairLoopbackPorts();
    final controller = ChatDemoController(callChannelPort: callPort);
    final remoteHuman = ReliableMessenger(remotePort, peerId: 'remote');

    final photoBytes = List<int>.generate(40 * 1024, (i) => (i * 7) % 251);
    await sendAttachment(
      remoteHuman,
      Attachment(
        id: 'call-photo',
        kind: MediaKind.image,
        contentType: 'image/jpeg',
        bytes: photoBytes,
      ),
    );
    await pumpEventQueue();

    expect(controller.entries, hasLength(1));
    final entry = controller.entries.single;
    expect(entry.attachment, isNotNull);
    expect(entry.attachment!.id, 'call-photo');
    expect(entry.attachment!.bytes, photoBytes);
    // Chunk frames were consumed by reassembly, never shown as raw text.
    expect(entry.message.text, '[image]');

    await remoteHuman.close();
    controller.dispose();
  });

  test('the periodic retry driver retransmits a pending message after the '
      'retry window elapses', () {
    fakeAsync((async) {
      final (callPort, remotePort) = pairLoopbackPorts();
      // The first transmission vanishes into a dead channel; retransmits
      // (driven by the controller's 500ms ticker) go through.
      final controller = ChatDemoController(
        callChannelPort: _DroppingPort(callPort, drop: 1),
      );
      final remoteHuman = ReliableMessenger(remotePort, peerId: 'remote');
      final remoteGot = <ChatMessage>[];
      remoteHuman.incoming.listen(remoteGot.add);

      unawaited(controller.sendText('retry me'));
      async.flushMicrotasks();
      expect(remoteGot, isEmpty); // first copy dropped, message pending

      // Ticker has fired (500/1000/1500ms) but the 2s retryAfter window has
      // not elapsed — nothing may be retransmitted yet.
      async.elapse(const Duration(milliseconds: 1500));
      expect(remoteGot, isEmpty);

      // Past the retry window the next tick retransmits, and the ack drains
      // the outbox.
      async.elapse(const Duration(seconds: 1));
      expect(remoteGot, hasLength(1));
      expect(remoteGot.single.text, 'retry me');

      controller.dispose();
      unawaited(remoteHuman.close());
      async.flushMicrotasks();
    });
  });

  test('default (no injected port) keeps the standalone loopback demo: '
      'echo peer answers', () async {
    final controller = ChatDemoController();
    await controller.sendText('hello');
    await pumpEventQueue();

    final texts = controller.entries.map((e) => e.message.text).toList();
    expect(texts, contains('echo: hello'));
    controller.dispose();
  });

  test('a caption frame from the remote side lands in captions — never as a '
      'chat bubble — and a final revision replaces its partial', () async {
    final (callPort, remotePort) = pairLoopbackPorts();
    final controller = ChatDemoController(callChannelPort: callPort);
    final remoteHuman = ReliableMessenger(remotePort, peerId: 'remote');

    Caption cap(String text, {required bool isFinal}) => Caption(
      segment: TranscriptSegment(
        id: 'cap-1',
        seq: 0,
        lang: 'en',
        text: text,
        isFinal: isFinal,
        startMs: 0,
      ),
      translations: {'fa': 'ترجمه: $text'},
    );

    await sendCaption(remoteHuman, cap('good morn', isFinal: false));
    await pumpEventQueue();

    expect(controller.entries, isEmpty); // not a bubble
    expect(controller.captions, hasLength(1));
    expect(controller.captions.single.segment.text, 'good morn');

    await sendCaption(remoteHuman, cap('good morning', isFinal: true));
    await pumpEventQueue();

    expect(controller.captions, hasLength(1)); // replaced, not appended
    expect(controller.captions.single.segment.text, 'good morning');
    expect(controller.captions.single.textFor('fa'), 'ترجمه: good morning');

    await remoteHuman.close();
    controller.dispose();
  });

  test(
    'loopback demo seeds translated captions through the real pipeline',
    () async {
      final controller = ChatDemoController();
      await pumpEventQueue();

      expect(controller.captions, hasLength(2));
      expect(
        controller.captions.first.textFor('fa'),
        'به نشست زنده خوش آمدید.',
      );
      controller.dispose();
    },
  );
}
