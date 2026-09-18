import 'dart:async';

import 'package:messaging/messaging.dart';
import 'package:test/test.dart';

/// In-memory lane fake, in the same spirit as `MemPort` in
/// reliable_messenger_test.dart, plus a settable [bufferedAmount] so
/// LaneSetPort's active-only backpressure rule is testable, plus
/// [injectInbound] so a merge test doesn't need a real peer wired up.
class FakeLanePort implements BufferedDataChannelPort {
  FakeLanePort({this.bufferedAmount});

  final _in = StreamController<List<int>>.broadcast(sync: true);
  FakeLanePort? peer;
  final sent = <List<int>>[];

  @override
  int? bufferedAmount;

  @override
  Stream<List<int>> get inbound => _in.stream;

  @override
  Future<void> send(List<int> frame) async {
    sent.add(frame);
    peer?._in.add(frame);
  }

  void injectInbound(List<int> frame) => _in.add(frame);

  @override
  Future<void> close() async {
    if (!_in.isClosed) await _in.close();
  }
}

void main() {
  test('a first transmission reaches only the active member', () async {
    final m0 = FakeLanePort();
    final m1 = FakeLanePort();
    final lane = LaneSetPort([m0, m1], activeIndex: () => 0);

    await lane.send([1, 2, 3]);

    expect(m0.sent, [
      [1, 2, 3],
    ]);
    expect(m1.sent, isEmpty);
  });

  test('a byte-identical resend fans out to the top-K members', () async {
    final m0 = FakeLanePort();
    final m1 = FakeLanePort();
    final m2 = FakeLanePort();
    final lane = LaneSetPort([m0, m1, m2], activeIndex: () => 0);
    final frame = [9, 9, 9];

    await lane.send(frame); // first transmission
    await lane.send(frame); // byte-identical resend

    expect(m0.sent, [frame, frame]); // active: both copies
    expect(m1.sent, [frame]); // fanout target #2 (default K=2)
    expect(m2.sent, isEmpty); // beyond K: untouched
  });

  test(
    'inbound data from either member surfaces on the merged stream',
    () async {
      final m0 = FakeLanePort();
      final m1 = FakeLanePort();
      final lane = LaneSetPort([m0, m1], activeIndex: () => 0);
      final received = <List<int>>[];
      lane.inbound.listen(received.add);

      m0.injectInbound([1]);
      m1.injectInbound([2]);
      await pumpEventQueue();

      expect(received, [
        [1],
        [2],
      ]);
    },
  );

  test('bufferedAmount reports only the active member, never a sum', () async {
    final m0 = FakeLanePort(bufferedAmount: 5);
    final m1 = FakeLanePort(bufferedAmount: 999999);
    var active = 0;
    final lane = LaneSetPort([m0, m1], activeIndex: () => active);

    expect(lane.bufferedAmount, 5);

    active = 1;
    expect(lane.bufferedAmount, 999999);
  });

  test('a clean multi-chunk transfer sends no more than a bare port would '
      '(no unconditional doubling)', () async {
    const chunkCount = 12;
    final frames = List<List<int>>.generate(
      chunkCount,
      (i) => List<int>.generate(64, (b) => (i * 31 + b) & 0xff),
    );

    // Baseline: what a bare single port records for the same sequence of
    // distinct, never-repeated chunks (a lossless, zero-retransmission
    // transfer never sends the same bytes twice).
    final bare = FakeLanePort();
    for (final f in frames) {
      await bare.send(f);
    }

    final m0 = FakeLanePort();
    final m1 = FakeLanePort();
    final m2 = FakeLanePort();
    final lane = LaneSetPort([m0, m1, m2], activeIndex: () => 0);
    for (final f in frames) {
      await lane.send(f);
    }

    final laneTotal = m0.sent.length + m1.sent.length + m2.sent.length;
    expect(laneTotal, bare.sent.length);
    expect(laneTotal, chunkCount);
    expect(m1.sent, isEmpty);
    expect(m2.sent, isEmpty);
  });

  test(
    'a single-member set is byte-for-byte equivalent to using it directly',
    () async {
      final only = FakeLanePort(bufferedAmount: 0);
      final lane = LaneSetPort([only], activeIndex: () => 0);
      final frame = [7, 7, 7];

      await lane.send(frame);
      await lane.send(frame); // a "resend" still has nowhere else to go

      expect(only.sent, [frame, frame]);
      expect(lane.bufferedAmount, only.bufferedAmount);

      only.bufferedAmount = 42;
      expect(lane.bufferedAmount, 42);
    },
  );
}
