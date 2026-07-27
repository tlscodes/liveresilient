/// End-to-end registration of the resilient fallback stack with the fabric.
///
/// The UDP lane runs against a real loopback echo server (`127.0.0.1`); no
/// test here reaches an external host. The remaining lanes are driven
/// through [LocalMeshLane]'s injectable peer callback so failover can be
/// scripted deterministically without standing up three more servers —
/// the lanes' own wire behaviour is covered in
/// `adaptive_transport/test/resilient/resilient_fallback_test.dart`.
library;

import 'dart:io';

import 'package:adaptive_transport/adaptive_transport.dart';
import 'package:connection_orchestrator/connection_orchestrator.dart';
import 'package:device_link/device_link.dart';
import 'package:test/test.dart';

class _ToggleConsent implements DeviceLinkConsent {
  _ToggleConsent(this.granted);

  @override
  bool granted;
}

/// A scriptable stand-in built on the real [LocalMeshLane], so the fabric
/// sees a genuine resilient lane rather than a bespoke fake.
class _ScriptedLane {
  _ScriptedLane(String name) {
    lane = LocalMeshLane(
      name: name,
      peerSender: (payload) async {
        sends++;
        if (!up) return const SendResult(SendStatus.transient);
        delivered.add(List<int>.from(payload));
        return const SendResult(SendStatus.ok, rttMs: 15);
      },
      peerProbe: () async => up,
    );
  }

  late final LocalMeshLane lane;
  bool up = true;
  int sends = 0;
  final delivered = <List<int>>[];
}

void main() {
  var clockMs = 0;
  late DtnBundleQueue queue;
  late ConnectionFabric fabric;

  setUp(() {
    clockMs = 0;
    queue = DtnBundleQueue();
    fabric = ConnectionFabric(fallbackQueue: queue, nowMs: () => clockMs);
  });

  tearDown(() => fabric.dispose());

  group('ResilientFallbackLanes · fabric registration', () {
    test(
      'registers every provided lane and reports them in the snapshot',
      () async {
        final udpEcho = await RawDatagramSocket.bind(
          InternetAddress.loopbackIPv4,
          0,
        );
        udpEcho.listen((event) {
          if (event != RawSocketEvent.read) return;
          final packet = udpEcho.receive();
          if (packet != null) {
            udpEcho.send(packet.data, packet.address, packet.port);
          }
        });
        addTearDown(udpEcho.close);

        final udp = PrimaryUdpLane(
          remote: HostPort(
            host: InternetAddress.loopbackIPv4.address,
            port: udpEcho.port,
          ),
        );
        addTearDown(udp.dispose);
        final relay = _ScriptedLane('wss');
        final poll = _ScriptedLane('https');
        final mesh = _ScriptedLane('mesh');

        final ids = ResilientFallbackLanes.registerAll(
          fabric,
          primaryUdp: udp,
          webSocketRelay: relay.lane,
          httpLongPoll: poll.lane,
          localMesh: mesh.lane,
        );

        expect(ids, [
          ResilientLaneIds.primaryUdp,
          ResilientLaneIds.webSocketRelay,
          ResilientLaneIds.httpLongPoll,
          ResilientLaneIds.localMesh,
        ]);
        expect(fabric.snapshot.lanes.map((l) => l.id).toSet(), ids.toSet());

        // Real probe round-trips against the loopback echo bring the fabric to
        // a live mode with the UDP lane present. Several are needed, not one:
        // ChannelHealth starts at the 9999 ms "unmeasured" RTT and converges
        // by EWMA (alpha 0.3), so a single sub-millisecond sample still leaves
        // the score below the degraded threshold.
        for (var i = 0; i < 20; i++) {
          await fabric.refresh();
        }
        expect(fabric.snapshot.mode, FabricMode.live);
      },
    );

    test('omitted lanes are simply not registered', () {
      final relay = _ScriptedLane('wss');
      final ids = ResilientFallbackLanes.registerAll(
        fabric,
        webSocketRelay: relay.lane,
      );

      expect(ids, [ResilientLaneIds.webSocketRelay]);
      expect(fabric.snapshot.lanes.single.id, ResilientLaneIds.webSocketRelay);
    });

    test('registering no lane at all is a caller error', () {
      expect(
        () => ResilientFallbackLanes.registerAll(fabric),
        throwsArgumentError,
      );
    });

    test(
      'mesh consent gates eligibility and a grant takes effect live',
      () async {
        final consent = _ToggleConsent(false);
        final mesh = _ScriptedLane('mesh');
        ResilientFallbackLanes.registerAll(
          fabric,
          localMesh: mesh.lane,
          meshConsent: consent,
        );

        expect(fabric.snapshot.lanes.single.eligible, isFalse);
        // Ineligible lane => nothing to carry with, so the frame parks.
        expect(
          await fabric.deliver(const [1, 2, 3, 4], bundleId: 'gated'),
          DeliveryOutcome.queuedForLater,
        );
        expect(mesh.sends, 0);

        consent.granted = true;
        // Consent is re-read on the next ranking pass, which publishes.
        await fabric.refresh();
        expect(fabric.snapshot.lanes.single.eligible, isTrue);
        expect(
          mesh.delivered,
          hasLength(1),
          reason: 'backlog drained on grant',
        );
      },
    );

    test('unregisterAll clears the stack and leaves the fabric offline', () {
      final relay = _ScriptedLane('wss');
      final mesh = _ScriptedLane('mesh');
      ResilientFallbackLanes.registerAll(
        fabric,
        webSocketRelay: relay.lane,
        localMesh: mesh.lane,
      );
      expect(fabric.snapshot.lanes, hasLength(2));

      ResilientFallbackLanes.unregisterAll(fabric);
      expect(fabric.snapshot.lanes, isEmpty);
      expect(fabric.snapshot.mode, FabricMode.offline);
    });
  });

  group('ResilientFallbackLanes · delivery through the fabric', () {
    test(
      'the fabric fails over down the registered stack with full delivery',
      () async {
        final relay = _ScriptedLane('wss');
        final poll = _ScriptedLane('https');
        final mesh = _ScriptedLane('mesh');

        ResilientFallbackLanes.registerAll(
          fabric,
          webSocketRelay: relay.lane,
          httpLongPoll: poll.lane,
          localMesh: mesh.lane,
        );

        const frame = [0xDE, 0xAD, 0xBE, 0xEF];

        // All up: the cheapest internet lane carries it.
        var outcome = await fabric.deliver(frame, bundleId: 'f1');
        expect(outcome, DeliveryOutcome.sentLive);
        expect(relay.delivered, hasLength(1));

        // Relay dies → long-poll takes over, no frame lost.
        relay.up = false;
        outcome = await fabric.deliver(frame, bundleId: 'f2');
        expect(outcome, DeliveryOutcome.sentLive);
        expect(poll.delivered, hasLength(1));

        // Long-poll dies → the local mesh peer carries it.
        poll.up = false;
        outcome = await fabric.deliver(frame, bundleId: 'f3');
        expect(outcome, DeliveryOutcome.sentLive);
        expect(mesh.delivered, hasLength(1));

        // Everything down → the frame is parked, not dropped.
        mesh.up = false;
        outcome = await fabric.deliver(frame, bundleId: 'f4');
        expect(outcome, DeliveryOutcome.queuedForLater);
        expect(queue.pendingCount, 1);

        // The primary recovers → the fabric drains the backlog with no caller
        // help. Recovery is asserted on the top lane deliberately: the fabric
        // drains through its single best-ranked lane, so reviving only the
        // last-resort mesh would not necessarily unblock the queue.
        relay.up = true;
        final drained = await fabric.refresh();
        expect(drained, 1);
        expect(queue.pendingCount, 0);
        expect(relay.delivered, hasLength(2));

        // Every frame offered was ultimately delivered exactly once.
        final all = [...relay.delivered, ...poll.delivered, ...mesh.delivered];
        expect(all, hasLength(4));
        expect(all.every((f) => f.length == 4), isTrue);
      },
    );
  });

  group('ResilientLaneEndpoints.fromEnvironment', () {
    test('reads all three WAN lanes from the environment', () {
      final endpoints = ResilientLaneEndpoints.fromEnvironment(const {
        ResilientLaneEndpoints.udpEnvVar: 'relay.example.net:7001',
        ResilientLaneEndpoints.wsEnvVar: 'wss://relay.example.net/ws',
        ResilientLaneEndpoints.httpEnvVar: 'https://relay.example.net/poll',
      });

      expect(endpoints.udpRemote!.host, 'relay.example.net');
      expect(endpoints.udpRemote!.port, 7001);
      expect(endpoints.relayUri, Uri.parse('wss://relay.example.net/ws'));
      expect(endpoints.longPollUri, Uri.parse('https://relay.example.net/poll'));
      expect(endpoints.hasAnyLane, isTrue);
    });

    test('an absent or blank variable falls back to the given default', () {
      final defaults = ResilientLaneEndpoints(
        relayUri: Uri.parse('wss://default.example.net/ws'),
      );
      final endpoints = ResilientLaneEndpoints.fromEnvironment(
        const {ResilientLaneEndpoints.wsEnvVar: '   '},
        defaults: defaults,
      );

      expect(endpoints.relayUri, Uri.parse('wss://default.example.net/ws'));
      expect(endpoints.udpRemote, isNull);
      expect(endpoints.longPollUri, isNull);
    });

    test('an empty environment configures nothing at all', () {
      final endpoints = ResilientLaneEndpoints.fromEnvironment(const {});
      expect(endpoints.hasAnyLane, isFalse);
    });

    test('mesh callbacks pass through from the defaults', () {
      Future<SendResult> send(List<int> _) async =>
          const SendResult(SendStatus.ok);
      final endpoints = ResilientLaneEndpoints.fromEnvironment(
        const {},
        defaults: ResilientLaneEndpoints(meshSender: send),
      );
      expect(endpoints.meshSender, same(send));
      expect(endpoints.hasAnyLane, isTrue);
    });

    test('a malformed endpoint throws instead of being dropped', () {
      // Silently ignoring a bad value ships a build with no fallback path
      // and no sign that anything is wrong.
      expect(
        () => ResilientLaneEndpoints.fromEnvironment(
          const {ResilientLaneEndpoints.udpEnvVar: 'relay.example.net'},
        ),
        throwsFormatException,
      );
      expect(
        () => ResilientLaneEndpoints.fromEnvironment(
          const {ResilientLaneEndpoints.udpEnvVar: 'relay.example.net:99999'},
        ),
        throwsFormatException,
      );
      expect(
        () => ResilientLaneEndpoints.fromEnvironment(
          const {ResilientLaneEndpoints.wsEnvVar: 'not-a-uri'},
        ),
        throwsFormatException,
      );
    });

    test('a relay host derives both WAN lanes from the worker schema', () {
      final endpoints = ResilientLaneEndpoints.fromEnvironment(const {
        ResilientLaneEndpoints.relayHostEnvVar: 'relay.example.workers.dev',
        ResilientLaneEndpoints.relaySessionEnvVar: 'sess-9f2c',
        ResilientLaneEndpoints.relayRoleEnvVar: 'b',
      });

      expect(
        endpoints.relayUri,
        Uri.parse(
          'wss://relay.example.workers.dev/ws?session=sess-9f2c&role=b',
        ),
      );
      expect(
        endpoints.longPollUri,
        Uri.parse(
          'https://relay.example.workers.dev/http?session=sess-9f2c&role=b',
        ),
      );
    });

    test('an explicit lane URI still wins over the derived one', () {
      final endpoints = ResilientLaneEndpoints.fromEnvironment(const {
        ResilientLaneEndpoints.relayHostEnvVar: 'relay.example.workers.dev',
        ResilientLaneEndpoints.wsEnvVar: 'wss://own.example.net/ws',
      });

      expect(endpoints.relayUri, Uri.parse('wss://own.example.net/ws'));
      expect(endpoints.longPollUri!.host, 'relay.example.workers.dev');
    });

    test('the worker factory rejects a bad session or role', () {
      expect(
        () => ResilientLaneEndpoints.cloudflareWorker(
          workerHost: 'relay.example.workers.dev',
          session: 'has spaces',
          role: 'a',
        ),
        throwsArgumentError,
      );
      expect(
        () => ResilientLaneEndpoints.cloudflareWorker(
          workerHost: 'relay.example.workers.dev',
          session: 'ok',
          role: 'caller',
        ),
        throwsArgumentError,
      );
    });

    test('the development echo set is opt-in, never a default', () {
      // These are liveness toys, not relays: a lane pointed at them looks
      // reachable while delivering nothing to the peer.
      expect(ResilientLaneEndpoints.fromEnvironment(const {}).hasAnyLane,
          isFalse);
      expect(
        ResilientLaneEndpoints.developmentEchoEndpoints.hasAnyLane,
        isTrue,
      );
    });
  });
}
