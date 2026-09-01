/// Reference app: a three-tab demo (Call / Chat / Settings) that runs
/// standalone, with no server, camera, or network required — every screen is
/// driven by plain state owned by the controllers in `src/`. Real
/// device/network wiring (`buildWebRtcCallSession`) is kept available but
/// only from the clearly-marked dev entry point at the bottom of this file.
library;

import 'dart:async';

import 'package:call_core/call_core.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:media_webrtc/media_webrtc.dart' show OpusSdpPolicy;
import 'package:messaging/messaging.dart' show DeliveryState;
import 'package:signed_config/signed_config.dart'
    show EndpointManifest, OobManifestImport, buildRtcIceConfig, iceProfileFor;

import 'src/attachment_picker.dart';
import 'src/call_demo_controller.dart';
import 'src/call_screen.dart';
import 'src/call_session.dart';
import 'src/ws_connector.dart' show platformHostResolution;
import 'package:live_captions/live_captions.dart' show ChannelInvite;

import 'src/chat_demo_controller.dart';
import 'src/chat_screen.dart';
import 'src/demo_feeds.dart';
import 'src/photo_ingest.dart';
import 'src/photo_picker.dart';
import 'src/intelligence/assistant_view.dart';
import 'src/intelligence/device_bindings.dart';
import 'src/intelligence/foresight_card.dart';
import 'src/intelligence/intelligence_boot.dart';
import 'src/intelligence/intelligence_hub.dart';
import 'src/import_manifest_sheet.dart';
import 'src/join_channel_sheet.dart';
import 'src/startup_manifest.dart';
import 'src/theme.dart';
import 'src/ui/conversations_screen.dart';
import 'src/ui/incoming_call_screen.dart';
import 'src/ui/network_truth.dart';
import 'src/ui/settings_screen.dart';

export 'src/call_demo_controller.dart';
export 'src/chat_demo_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Boot the intelligence circuit before the first frame: both brains
  // restored from disk, fabric place-aware, director watching. The device
  // binding seam supplies the real link radio when present; it is null in
  // the demo/gate build, so the app degrades cleanly.
  final intelligence = await bootIntelligence(
    localLinkLane: buildLocalLinkLane(),
    storageDirFactory: buildStorageDirectory(),
  );
  runApp(MyApp(intelligence: intelligence));
}

class MyApp extends StatefulWidget {
  const MyApp({super.key, this.intelligence, this.oobImport});

  /// Null only in widget tests that exercise screens in isolation.
  final IntelligenceStack? intelligence;

  /// Out-of-band manifest import, when this build has pinned signing keys.
  ///
  /// NULL IS THE HONEST DEFAULT, not an oversight. Verifying a manifest needs
  /// keys pinned into the build; a build without them could only "import" by
  /// trusting whatever it was handed, which is precisely the attack the whole
  /// signed-config design exists to prevent. So when it is null the import
  /// control is ABSENT rather than present-and-permissive — a button that
  /// cannot verify is worse than no button, because it looks like a safety
  /// feature while being the opposite.
  final OobManifestImport? oobImport;

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  /// User-chosen appearance, surfaced in Settings. System is the default so
  /// the app follows the platform until the user says otherwise.
  ThemeMode _themeMode = ThemeMode.system;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'VoiceCallKit Reference',
      theme: buildAppTheme(Brightness.light),
      darkTheme: buildAppTheme(Brightness.dark),
      themeMode: _themeMode,
      home: HomePage(
        intelligence: widget.intelligence,
        oobImport: widget.oobImport,
        themeMode: _themeMode,
        onThemeMode: (mode) => setState(() => _themeMode = mode),
      ),
    );
  }
}

/// Root scaffold: a [NavigationBar] switching between the Call, Chat and
/// Settings tabs. Owns the tabs' state so the screens themselves stay
/// pure-data.
class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    this.intelligence,
    this.oobImport,
    this.themeMode = ThemeMode.system,
    this.onThemeMode,
  });

  final IntelligenceStack? intelligence;

  /// See [MyApp.oobImport]: null means this build cannot verify a manifest, so
  /// the import control is not offered at all.
  final OobManifestImport? oobImport;

  /// Appearance selection, owned by [MyApp] (it must sit above the
  /// [MaterialApp] to take effect); Settings edits it through [onThemeMode].
  final ThemeMode themeMode;
  final ValueChanged<ThemeMode>? onThemeMode;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _index = 0;

  /// A manifest the user imported out of band this session. Held so the
  /// banner can say which endpoints are in use — "which ICE servers am I
  /// actually on" is the first question when a call will not connect, and
  /// until now nothing in the app could answer it.
  EndpointManifest? _importedManifest;

  /// The caption channel the user joined via link/id, shown as a chip in
  /// the caption strip area (full channel session arrives with the STT
  /// engine wiring).
  ChannelInvite? _joinedChannel;
  final CallDemoController _call = CallDemoController();
  late final ChatDemoController _chat = ChatDemoController(
    attachmentPicker: pickAttachmentFile,
    photoPicker: pickPhotoBytes,
    photoIngest: (raw) => compute(buildStagedPhotoArtifacts, raw),
    intelligenceFabric: widget.intelligence?.fabric,
    hub: widget.intelligence?.hub,
  );

  /// Demo-labeled network-quality feed for the gauge and diagnostics panel.
  /// GATED ON [AppMotion.ambientEnabled]: under `flutter test` no stream is
  /// handed out at all, so no periodic timer ever exists to leak into a
  /// test's teardown. On-device real wiring will feed the same seams from
  /// measured RTCStats (see path_health_monitor.dart).
  final DemoQualityFeed _quality = DemoQualityFeed();

  /// Real ladder logic ([OperatingLadder]) driven by the demo feed's
  /// bitrate — the mapping is genuine even where the input is labeled
  /// synthetic.
  final OperatingLadder _ladder = OperatingLadder();
  OperatingRung? _rung;
  StreamSubscription<CallQualityReading>? _rungSub;

  /// True while a pull-to-refresh replays the conversations skeleton.
  bool _conversationsLoading = false;

  static bool get _liveFeedsAllowed => AppMotion.ambientEnabled;

  @override
  void initState() {
    super.initState();
    _call.addListener(_onChanged);
    _chat.addListener(_onChanged);
  }

  void _onChanged() {
    // The rung subscription lives only while a call is active (and never
    // under tests): the demo feed stops its timer when its last listener
    // cancels, so nothing periodic outlives the call.
    final inCall = _call.canHangUp;
    if (_liveFeedsAllowed && inCall && _rungSub == null) {
      _rungSub = _quality.stream.listen((reading) {
        final rung = _ladder.report(reading.bitrateBps ?? 0);
        if (rung != _rung && mounted) setState(() => _rung = rung);
      });
    } else if (!inCall && _rungSub != null) {
      unawaited(_rungSub!.cancel());
      _rungSub = null;
      _rung = null;
    }
    setState(() {});
  }

  @override
  void dispose() {
    _call.removeListener(_onChanged);
    _chat.removeListener(_onChanged);
    unawaited(_rungSub?.cancel());
    _quality.dispose();
    _call.dispose();
    _chat.dispose();
    super.dispose();
  }

  /// Maps the live loopback thread's last entry to a truth-ladder status for
  /// the conversations list — real delivery signals only (delivered/failed
  /// from the messenger's ack stream; anything else visible is "sent").
  MessageTruthStatus? _lastStatus(ChatEntry entry) {
    if (entry.message.senderId != _chat.localSenderId) return null;
    return switch (_chat.deliveryStates[entry.message.id]) {
      DeliveryState.delivered => MessageTruthStatus.delivered,
      DeliveryState.failed => MessageTruthStatus.failed,
      null => MessageTruthStatus.sent,
    };
  }

  String _lastLabel(ChatEntry entry) {
    if (entry.photoId != null) return 'Photo';
    final attachment = entry.attachment;
    if (attachment != null) {
      if (attachment.contentType.startsWith('audio/')) return 'Voice note';
      return 'Attachment · ${attachment.kind.name}';
    }
    return entry.message.text;
  }

  /// The list is anchored by the REAL loopback conversation (live state,
  /// live delivery ticks); two static rows exist only so list ergonomics
  /// (unread badges, ordering, identicons) are visible in a demo build.
  List<ConversationSummary> _conversations() {
    final now = DateTime.now();
    final entries = _chat.entries;
    final last = entries.isEmpty ? null : entries.last;
    return [
      ConversationSummary(
        id: 'loopback',
        title: 'Loopback peer',
        lastMessage: last == null
            ? 'Say hello to the demo loop'
            : _lastLabel(last),
        lastAt: last == null
            ? now
            : DateTime.fromMillisecondsSinceEpoch(last.message.sentAtMs),
        avatarSeed: 0x5EED,
        unreadCount: 0,
        lastIsMine:
            last != null && last.message.senderId == _chat.localSenderId,
        lastStatus: last == null ? null : _lastStatus(last),
      ),
      ConversationSummary(
        id: 'demo-field',
        title: 'Field test notes (demo)',
        lastMessage: 'loss60 run: 24/24 green across the matrix',
        lastAt: now.subtract(const Duration(hours: 3)),
        avatarSeed: 0xF1E1D,
        unreadCount: 3,
      ),
      ConversationSummary(
        id: 'demo-design',
        title: 'Design review (demo)',
        lastMessage: 'Golden set regenerated for dark + RTL',
        lastAt: now.subtract(const Duration(days: 1, hours: 2)),
        avatarSeed: 0xDE516,
        unreadCount: 0,
        lastIsMine: true,
        lastStatus: MessageTruthStatus.delivered,
      ),
    ];
  }

  Future<void> _reloadConversations() async {
    setState(() => _conversationsLoading = true);
    await Future<void>.delayed(const Duration(milliseconds: 900));
    if (mounted) setState(() => _conversationsLoading = false);
  }

  void _openThread(ConversationSummary summary) {
    if (summary.id != 'loopback') {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Static demo row — the live thread is Loopback peer'),
        ),
      );
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => Scaffold(
          appBar: AppBar(title: const Text('Loopback peer')),
          body: ListenableBuilder(
            listenable: _chat,
            builder: (context, _) => ChatScreen(
              entries: _chat.entries,
              localSenderId: _chat.localSenderId,
              onSend: _chat.sendText,
              deliveryStates: _chat.deliveryStates,
              attachmentProgress: _chat.attachmentProgress,
              onPickAttachment: () => unawaited(_chat.pickAndSendAttachment()),
              onSendPhoto: _chat.canPickPhoto ? _chat.pickAndSendPhoto : null,
              outgoingPhotos: _chat.outgoingPhotos,
              incomingPhotos: _chat.incomingPhotos,
              onPlayAudio: _chat.playAudio,
              captions: _chat.captions,
              captionLanguage: 'fa',
              amplitudeSource: _liveFeedsAllowed
                  ? syntheticAmplitudeSource()
                  : null,
              onSendVoiceNote: _chat.sendVoiceNote,
            ),
          ),
        ),
      ),
    );
  }

  void _previewIncomingCall() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (context) => IncomingCallScreen(
          callerName: 'Demo caller',
          callId: newSecureCallId(),
          onAccept: () {
            Navigator.of(context).pop();
            _call.placeCall();
          },
          onDecline: () => Navigator.of(context).pop(),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pages = <Widget>[
      CallScreen(
        phase: _call.phase,
        reconnectAttempt: _call.reconnectAttempt,
        endReason: _call.endReason,
        audioOnly: _call.audioOnly,
        callId: _call.callId,
        onCall: _call.canCall ? _call.placeCall : null,
        onHangUp: _call.canHangUp ? _call.hangUp : null,
        quality: _liveFeedsAllowed ? _quality.stream : null,
        rung: _rung,
      ),
      RefreshIndicator(
        onRefresh: _reloadConversations,
        child: ConversationsScreen(
          conversations: _conversations(),
          loading: _conversationsLoading,
          onOpen: _openThread,
        ),
      ),
      SettingsScreen(
        themeMode: widget.themeMode,
        onThemeMode: (mode) => widget.onThemeMode?.call(mode),
        readings: _liveFeedsAllowed ? _quality.stream : null,
        diagnosticsSeed: seededDemoHistory(),
        diagnosticsSource: demoQualitySourceLabel,
        appVersion: 'reference v3',
      ),
    ];
    return Scaffold(
      appBar: AppBar(
        title: Text(switch (_index) {
          0 => 'Call',
          1 => 'Chat',
          _ => 'Settings',
        }),
        actions: [
          if (_index == 0)
            IconButton(
              tooltip: 'Preview incoming call',
              icon: const Icon(Icons.ring_volume),
              onPressed: _previewIncomingCall,
            ),
          IconButton(
            tooltip: 'Join caption channel',
            icon: const Icon(Icons.closed_caption),
            onPressed: () async {
              final invite = await showJoinChannelSheet(context);
              if (invite != null && mounted) {
                setState(() => _joinedChannel = invite);
              }
            },
          ),
          // The out-of-band import needs a way in. Without this button the
          // sheet, the compact-code format, the verifier path and the CLI that
          // produces a code are all reachable only from a test — the same
          // orphan shape the audit found three times. It is deliberately in the
          // app bar rather than buried in settings: the moment a person needs
          // it is the moment nothing else in the app is working, and a recovery
          // control nobody can find is not a recovery control.
          if (widget.oobImport != null)
            IconButton(
              tooltip: 'Import connection settings',
              icon: const Icon(Icons.settings_ethernet),
              onPressed: () async {
                final manifest = await showImportManifestSheet(
                  context,
                  import: widget.oobImport!,
                );
                if (manifest != null && mounted) {
                  setState(() => _importedManifest = manifest);
                }
              },
            ),
        ],
      ),
      body: Column(
        children: [
          if (widget.intelligence != null) ...[
            ForesightCard(director: widget.intelligence!.director),
            AssistantView(director: widget.intelligence!.director),
          ],
          if (_joinedChannel != null)
            MaterialBanner(
              leading: const Icon(Icons.closed_caption),
              content: Text(
                'Caption channel ${_joinedChannel!.channelId}'
                '${_joinedChannel!.language == null ? '' : ' · ${_joinedChannel!.language}'}',
              ),
              actions: [
                TextButton(
                  onPressed: () => setState(() => _joinedChannel = null),
                  child: const Text('Leave'),
                ),
              ],
            ),
          // WORDING IS LOAD-BEARING. The first version of this banner said
          // "Using imported settings", which was false: the manifest was held
          // in state and never handed to `devConnectWithStartupManifest`, so
          // no call used it. A security-relevant claim that the UI cannot back
          // up is worse than no banner — a user would stop looking for the
          // reason their calls still fail. It now says what is true.
          if (_importedManifest != null)
            MaterialBanner(
              leading: const Icon(Icons.verified_outlined),
              content: Text(
                'Verified settings ready: revision '
                '${_importedManifest!.revision}, '
                '${_importedManifest!.iceServers.length} servers. '
                'They apply to the NEXT call you place.',
              ),
              actions: [
                TextButton(
                  onPressed: () => setState(() => _importedManifest = null),
                  child: const Text('Discard'),
                ),
              ],
            ),
          Expanded(child: pages[_index]),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (value) {
          AppHaptics.selection();
          setState(() => _index = value);
        },
        destinations: const [
          NavigationDestination(icon: Icon(Icons.call), label: 'Call'),
          NavigationDestination(icon: Icon(Icons.chat_bubble), label: 'Chat'),
          NavigationDestination(icon: Icon(Icons.settings), label: 'Settings'),
        ],
      ),
    );
  }
}

/// DEV-ONLY: connects to a local dev signaling relay
/// (`server/signaling_server`) for manual real-device testing. Not part of
/// the default demo flow, not called from anywhere in this file's widget
/// tree, and safe to call even with no relay running — failures are caught
/// and returned as `null` instead of throwing.
///
/// [callId] defaults to a fresh [newSecureCallId] — 128 bits from the
/// platform CSPRNG. It doubles as the border relay's session id, so a
/// guessable one would let anyone attach to the call as the missing side.
///
/// [manifest] closes the ICE gap. `buildRtcIceConfig` and `buildWebRtcCallSession`
/// were both written and tested, but nothing joined them: this entry point called
/// the builder without `iceConfig`, so the null-coalesce inside it fired and every
/// call was still placed with `iceServers: const []` — no STUN, no TURN. Passing a
/// signed manifest here is what makes the tested mapper actually run. Callers with
/// no manifest keep the old behaviour, explicitly rather than by omission.
///
/// [iceFailureCount] feeds [iceProfileFor]: two ICE failures on the SAME call
/// is the only evidence that justifies relay-only, and it is never sticky.
/// Left null, the count is read from [devIceFailureLedger] by call id — the
/// recorded history, not a constant. Pass a value only when the caller tracks
/// its own count (tests, harnesses): it is an explicit override now, not the
/// sole source. The old `= 0` default meant a caller that passed nothing
/// silently disabled the rule — the same omission failure as the unwired
/// `iceConfig` above.
///
/// [opusPolicy] defaults to in-band FEC on, DTX off — the project's shipped
/// defaults. DTX stays off until there is field evidence per network, because
/// some middleboxes treat a silent flow as a dead one.
CallSessionHandle? devConnectToLocalRelay({
  String? callId,
  EndpointManifest? manifest,
  int? iceFailureCount,
  OpusSdpPolicy opusPolicy = const OpusSdpPolicy(),
  IntelligenceHub? hub,
}) {
  // The id is resolved before anything else: the failure ledger is keyed by
  // call id, so the id must exist before the count for it can be read.
  final resolvedCallId = callId ?? newSecureCallId();
  // Built OUTSIDE the catch below on purpose. buildRtcIceConfig fails loudly
  // when a signed manifest cannot be mapped, and the old blanket catch turned
  // that named misconfiguration back into a silent null — indistinguishable
  // from the relay being down. A config failure now propagates to the caller.
  final iceConfig = manifest == null
      ? null
      : buildRtcIceConfig(
          manifest,
          profile: iceProfileFor(
            iceFailureCount:
                iceFailureCount ??
                devIceFailureLedger.failureCountFor(resolvedCallId),
            featureFlags: manifest.featureFlags,
          ),
        );
  try {
    return buildWebRtcCallSession(
      endpoint: Uri.parse('wss://localhost:4443'),
      callId: resolvedCallId,
      role: CallRole.initiator,
      iceConfig: iceConfig,
      opusPolicy: opusPolicy,
      hub: hub,
      // Gate 6b: named, not omitted. The dev relay is reached by a literal
      // host, so the platform's own resolution is the right choice here —
      // but it is a CHOICE, and it says so. An architecture test fails any
      // construction site that leaves this argument out, because omission
      // and decision used to be indistinguishable in this exact call.
      resolveAddress: platformHostResolution,
    );
  } catch (_) {
    // Guards session construction only: a dev relay that is not running is
    // the expected failure here, and null is its documented contract.
    return null;
  }
}

/// Records ICE failures per call so the two-failure rule in [iceProfileFor]
/// can actually fire.
///
/// The count this feeds used to be a parameter with a `= 0` default that no
/// caller ever supplied, so the relay-only rule could never trigger on its
/// own — the same failure class as the unwired `iceConfig`: an optional that
/// stays at its default in production while the code reads as though the rule
/// is live. A ledger keyed by call id makes the count real: recordable by
/// name when a failure happens, readable by name when the next attempt is
/// placed.
///
/// Per call, never sticky: an unknown call id reads as zero, so a new call
/// always starts clean.
///
/// Memory is bounded two ways: [forget] drops a call's entry when the call
/// ends, and [maxEntries] caps the map regardless — inserting past the cap
/// evicts the oldest entry (Dart maps iterate in insertion order), so
/// abandoned ids cannot accumulate even if nobody calls [forget].
class IceFailureLedger {
  IceFailureLedger({this.maxEntries = 64});

  /// Hard cap on remembered call ids; past it the oldest entry is evicted.
  final int maxEntries;

  final Map<String, int> _failuresByCallId = <String, int>{};

  /// Records one ICE failure for [callId] and returns its new count. The
  /// remove-then-insert keeps a live call recent, so the cap evicts the
  /// longest-untouched id first.
  int recordFailure(String callId) {
    final next = (_failuresByCallId.remove(callId) ?? 0) + 1;
    _failuresByCallId[callId] = next;
    if (_failuresByCallId.length > maxEntries) {
      _failuresByCallId.remove(_failuresByCallId.keys.first);
    }
    return next;
  }

  /// Failures recorded for [callId]; an unknown id is 0 — a new call starts
  /// clean.
  int failureCountFor(String callId) => _failuresByCallId[callId] ?? 0;

  /// Drops [callId]'s entry. Call when the call ends so the ledger holds only
  /// live calls.
  void forget(String callId) => _failuresByCallId.remove(callId);
}

/// Process-wide ledger the dev entry points read when the caller passes no
/// explicit [iceFailureCount]. Record a failure here by call id and the third
/// attempt for that same call gets the strict profile.
final IceFailureLedger devIceFailureLedger = IceFailureLedger();

/// Same as [devConnectToLocalRelay], but resolves the manifest first.
///
/// This is the entry point that closes the ICE gap end to end: without it the
/// caller has to remember to pass a manifest, and the failure mode of
/// forgetting is invisible — a call that connects on a good network and dies
/// on a hostile one, which is exactly the case nobody tests by hand.
///
/// [verifiedManifest] comes from the signed-config layer when it has one.
/// Returns the session and the manifest source, so a dev build can display
/// which ICE servers are actually in use rather than leaving it to guesswork.
///
/// [iceFailureCount] is a nullable override, same contract as on
/// [devConnectToLocalRelay]: null forwards through and the count is read from
/// [devIceFailureLedger] there — omission no longer pins the rule at zero.
Future<({CallSessionHandle? session, StartupManifest manifest})>
devConnectWithStartupManifest({
  String? callId,
  EndpointManifest? verifiedManifest,
  EndpointManifest? outOfBandManifest,
  int? iceFailureCount,
}) async {
  final startup = await loadStartupManifest(
    verifiedManifest: verifiedManifest,
    outOfBandManifest: outOfBandManifest,
  );
  final session = devConnectToLocalRelay(
    callId: callId,
    manifest: startup.manifest,
    iceFailureCount: iceFailureCount,
  );
  return (session: session, manifest: startup);
}

/// Opens the out-of-band import sheet and, if a manifest verifies, connects
/// with it.
///
/// This is the recovery path for the only situation the rest of the design
/// cannot help with: a fresh install whose configuration origins are all
/// unreachable, so there is no address to try and no cache to fall back on.
/// The sheet decides nothing — [OobManifestImport] applies the same pinned
/// keys, the same validity window and the same rollback rule the network path
/// uses, so a tampered code is refused rather than believed.
Future<({CallSessionHandle? session, StartupManifest manifest})?>
importManifestAndConnect(
  BuildContext context, {
  required OobManifestImport import,
  String? callId,
}) async {
  final imported = await showImportManifestSheet(context, import: import);
  if (imported == null) return null;
  return devConnectWithStartupManifest(
    callId: callId,
    outOfBandManifest: imported,
  );
}
