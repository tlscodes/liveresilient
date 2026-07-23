/// Caption channels — the modernized successor of the old Agora audio-room
/// join flow (6-digit code typed at login, admins-as-speakers, host
/// presence timer), rebuilt on THIS kit's real caption pipeline:
///
/// - **Join by id OR invite link**: [ChannelInvite.parse] accepts a bare
///   channel code, the app's own `vck://captions/<id>` deeplink, or an
///   `https://<host>/c/<id>` web link — one parser, every entry path the
///   old apps had (typed code, custom scheme) plus the web link they
///   lacked.
/// - **Roles**: the old `admins ⇒ publisher, everyone else muted` rule
///   becomes [ChannelRole] (host / speaker / listener) enforced at
///   [CaptionChannel.addSegment].
/// - **Per-member language**: the old group's dead free-text `language`
///   field becomes live routing — every member declares a language and
///   receives captions via `Caption.textFor(lang)`.
/// - **Presence**: the old host-offline timer generalizes to a heartbeat
///   deadline per member ([CaptionChannel.expireStale]).
///
/// Pure Dart, injectable clock, zero platform/vendor code — the transport
/// that carries [CaptionFrame]s stays whatever the app already uses (the
/// call data channel, a relay, anything frame-based).
library;

import 'dart:async';

import 'caption.dart';
import 'caption_pipeline.dart';
import 'transcript_segment.dart';
import 'translator.dart';

/// What a member is allowed to do in a caption channel.
enum ChannelRole {
  /// Created the channel; can speak and manage membership.
  host,

  /// May feed speech segments into the channel.
  speaker,

  /// Receives captions only (the old force-muted subscriber, made honest).
  listener,
}

/// A parsed, validated channel invite — from a bare id, the app scheme, or
/// a web link.
class ChannelInvite {
  ChannelInvite({required this.channelId, this.language}) {
    if (!isValidChannelId(channelId)) {
      throw ArgumentError.value(channelId, 'channelId');
    }
  }

  /// The channel to join.
  final String channelId;

  /// Optional preferred caption language carried by the invite
  /// (`?lang=fa`), so the joiner lands with captions already localized.
  final String? language;

  /// Channel ids: 4-32 chars of `A-Z a-z 0-9 - _` (covers the old 6-digit
  /// codes and readable slugs like `friday-standup`).
  static final RegExp _idPattern = RegExp(r'^[A-Za-z0-9_-]{4,32}$');

  static bool isValidChannelId(String id) => _idPattern.hasMatch(id);

  /// Parses any accepted invite form; returns null when [input] is not an
  /// invite:
  /// - `123456` / `friday-standup` (bare id)
  /// - `vck://captions/123456?lang=fa` (app deeplink)
  /// - `https://any.host/c/123456?lang=fa` (web link)
  static ChannelInvite? parse(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) return null;
    if (isValidChannelId(trimmed)) {
      return ChannelInvite(channelId: trimmed);
    }
    final uri = Uri.tryParse(trimmed);
    if (uri == null) return null;
    String? id;
    if (uri.scheme == 'vck' &&
        uri.host == 'captions' &&
        uri.pathSegments.length == 1) {
      id = uri.pathSegments.single;
    } else if ((uri.scheme == 'https' || uri.scheme == 'http') &&
        uri.pathSegments.length == 2 &&
        uri.pathSegments.first == 'c') {
      id = uri.pathSegments[1];
    }
    if (id == null || !isValidChannelId(id)) return null;
    final lang = uri.queryParameters['lang'];
    return ChannelInvite(
      channelId: id,
      language: (lang == null || lang.isEmpty) ? null : lang,
    );
  }

  /// The app deeplink for this invite.
  Uri toAppLink() => Uri(
    scheme: 'vck',
    host: 'captions',
    pathSegments: [channelId],
    queryParameters: language == null ? null : {'lang': language!},
  );

  /// The shareable web link for this invite.
  Uri toWebLink({String host = 'vck.app'}) => Uri(
    scheme: 'https',
    host: host,
    pathSegments: ['c', channelId],
    queryParameters: language == null ? null : {'lang': language!},
  );
}

/// One member of a caption channel.
class ChannelMember {
  ChannelMember({
    required this.id,
    required this.name,
    required this.role,
    required this.language,
    required this.lastSeen,
  }) {
    if (id.isEmpty) throw ArgumentError.value(id, 'id');
    if (language.isEmpty) throw ArgumentError.value(language, 'language');
  }

  final String id;
  final String name;
  final ChannelRole role;

  /// The language this member reads captions in.
  final String language;

  /// Last heartbeat, on the channel's injected clock.
  final DateTime lastSeen;

  ChannelMember copyWith({
    ChannelRole? role,
    String? language,
    DateTime? lastSeen,
  }) => ChannelMember(
    id: id,
    name: name,
    role: role ?? this.role,
    language: language ?? this.language,
    lastSeen: lastSeen ?? this.lastSeen,
  );
}

/// A caption addressed to one member, already localized for them.
class MemberCaption {
  const MemberCaption({
    required this.memberId,
    required this.caption,
    required this.text,
  });

  final String memberId;
  final Caption caption;

  /// The caption text in the member's language (translation or fallback).
  final String text;
}

/// A live caption channel: roster + roles + per-language caption fan-out
/// over the real [CaptionPipeline].
class CaptionChannel {
  CaptionChannel({
    required this.channelId,
    required ChannelMember host,
    required Translator translator,
    this.heartbeatTimeout = const Duration(seconds: 30),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now {
    if (!ChannelInvite.isValidChannelId(channelId)) {
      throw ArgumentError.value(channelId, 'channelId');
    }
    if (host.role != ChannelRole.host) {
      throw ArgumentError('the founding member must have the host role');
    }
    _members[host.id] = host;
    _rebuildPipeline(translator);
  }

  final String channelId;

  /// A member whose heartbeat is older than this is expired by
  /// [expireStale] (the old host-offline timer, for everyone).
  final Duration heartbeatTimeout;

  final DateTime Function() _now;
  final Map<String, ChannelMember> _members = {};
  late CaptionPipeline _pipeline;
  late StreamSubscription<Caption> _pipelineSub;
  final _memberCaptions = StreamController<MemberCaption>.broadcast();
  final _rosterChanges = StreamController<List<ChannelMember>>.broadcast();
  bool _closed = false;

  /// Captions fanned out per member, localized to each member's language.
  Stream<MemberCaption> get memberCaptions => _memberCaptions.stream;

  /// Emits the full roster after every membership change.
  Stream<List<ChannelMember>> get rosterChanges => _rosterChanges.stream;

  List<ChannelMember> get members => List.unmodifiable(_members.values);

  /// The set of languages the pipeline currently translates into.
  Set<String> get activeLanguages =>
      _members.values.map((m) => m.language).toSet();

  void _rebuildPipeline(Translator translator) {
    _pipeline = CaptionPipeline(
      translator: translator,
      targetLanguages: activeLanguages.toList()..sort(),
    );
    _pipelineSub = _pipeline.captions.listen(_fanOut);
    _translator = translator;
  }

  late Translator _translator;

  Future<void> _swapPipeline() async {
    final old = _pipeline;
    await _pipelineSub.cancel();
    _rebuildPipeline(_translator);
    await old.close();
  }

  void _fanOut(Caption caption) {
    if (_memberCaptions.isClosed) return;
    for (final member in _members.values) {
      _memberCaptions.add(
        MemberCaption(
          memberId: member.id,
          caption: caption,
          text: caption.textFor(member.language),
        ),
      );
    }
  }

  void _emitRoster() {
    if (!_rosterChanges.isClosed) _rosterChanges.add(members);
  }

  /// Joins via a parsed [invite] (or direct parameters). Re-joining with
  /// an existing id refreshes the heartbeat and updates name/language.
  /// Returns the resulting member. New joiners are listeners — the old
  /// "everyone but admins is muted" rule; the host promotes explicitly.
  Future<ChannelMember> join({
    required String memberId,
    required String name,
    String language = 'en',
    ChannelInvite? invite,
  }) async {
    _ensureOpen();
    final lang = invite?.language ?? language;
    final existing = _members[memberId];
    final member =
        existing?.copyWith(language: lang, lastSeen: _now()) ??
        ChannelMember(
          id: memberId,
          name: name,
          role: ChannelRole.listener,
          language: lang,
          lastSeen: _now(),
        );
    final languagesBefore = activeLanguages;
    _members[memberId] = member;
    if (activeLanguages.difference(languagesBefore).isNotEmpty) {
      await _swapPipeline();
    }
    _emitRoster();
    return member;
  }

  /// Host-only: change [memberId]'s role (promote listener → speaker, or
  /// demote). Throws [StateError] unless [byMemberId] is the host.
  void setRole({
    required String byMemberId,
    required String memberId,
    required ChannelRole role,
  }) {
    _ensureOpen();
    if (_members[byMemberId]?.role != ChannelRole.host) {
      throw StateError('only the host may change roles');
    }
    final member = _members[memberId];
    if (member == null) {
      throw StateError('no such member: $memberId');
    }
    if (role == ChannelRole.host) {
      throw StateError('host role cannot be granted; transfer not supported');
    }
    _members[memberId] = member.copyWith(role: role);
    _emitRoster();
  }

  /// Feeds one speech segment from [memberId] into the channel's caption
  /// pipeline. Only hosts and speakers may speak (the enforced version of
  /// the old force-mute).
  void addSegment(String memberId, TranscriptSegment segment) {
    _ensureOpen();
    final member = _members[memberId];
    if (member == null || member.role == ChannelRole.listener) {
      throw StateError('member $memberId may not publish captions');
    }
    _pipeline.add(segment);
  }

  /// Refreshes [memberId]'s presence heartbeat.
  void heartbeat(String memberId) {
    _ensureOpen();
    final member = _members[memberId];
    if (member != null) {
      _members[memberId] = member.copyWith(lastSeen: _now());
    }
  }

  /// Removes members whose heartbeat exceeded [heartbeatTimeout]; returns
  /// the removed members. The host expiring does NOT end the channel —
  /// captions keep flowing for the remaining members (graceful-survival
  /// rule, unlike the old app's hard "host went offline").
  Future<List<ChannelMember>> expireStale() async {
    _ensureOpen();
    final cutoff = _now().subtract(heartbeatTimeout);
    final expired = _members.values
        .where((m) => m.lastSeen.isBefore(cutoff))
        .toList();
    if (expired.isEmpty) return expired;
    for (final member in expired) {
      _members.remove(member.id);
    }
    await _swapPipeline();
    _emitRoster();
    return expired;
  }

  Future<void> leave(String memberId) async {
    _ensureOpen();
    if (_members.remove(memberId) != null) {
      await _swapPipeline();
      _emitRoster();
    }
  }

  void _ensureOpen() {
    if (_closed) throw StateError('CaptionChannel is closed');
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _pipelineSub.cancel();
    await _pipeline.close();
    await _memberCaptions.close();
    await _rosterChanges.close();
  }
}
