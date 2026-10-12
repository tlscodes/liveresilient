// Phase چ: a sealed letter seen while the app is closed (docs/ch-background-design.md).
//
// Compiled in only with --dart-define=SEALED_BACKGROUND=true: every use sits
// behind the const [kSealedBackground], so a normal build drops this code and
// its strings. iOS wakes the app through BGTaskScheduler (Swift side,
// AppDelegate.swift); the handler calls [SealedBackground.channelName] with
// `turn`, and this file runs one bounded look: drain the shelves over the TXT
// lane, post a content-free local notification per new letter, journal it.
//
// When iOS grants the wake is iOS's business. Nothing here estimates it: the
// journal holds what happened (bg_turn.begin/end) and nothing else.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import '../call_session.dart' show defaultBorderRelayHost;
import '../intelligence/device_bindings.dart';
import '../peer_identity.dart';
import 'sealed_letter_service.dart';

const bool kSealedBackground = bool.fromEnvironment('SEALED_BACKGROUND');

/// The flag build is TXT-only (no HTTPS fallback), so a turn's lane is txt by
/// construction; any other build reports `mixed` and never counts.
const bool kSealedTxtOnly = bool.fromEnvironment('SEALED_TXT_ONLY');

/// The result of asking for a local notification for one letter.
class SealedNotifyResult {
  const SealedNotifyResult({required this.auth, this.addError});
  final String auth;
  final String? addError;
}

/// One background turn's bounded work. Pure of platform: the service, the
/// notifier, the clock and the journal are handed in.
class SealedBackgroundTurn {
  SealedBackgroundTurn({
    required this.service,
    required this.notify,
    required this.journal,
    DateTime Function()? clock,
    this.deadline = const Duration(seconds: 25),
    this.drain = const Duration(seconds: 15),
    this.until,
    this.lane = kSealedTxtOnly ? 'txt' : 'mixed',
  }) : _clock = clock ?? DateTime.now;

  /// The service to drain; null when this install has no identity yet.
  final Future<SealedLetterService?> Function() service;
  final Future<SealedNotifyResult> Function(String letterId) notify;
  final void Function(String event, Map<String, Object?> fields) journal;
  final DateTime Function() _clock;

  /// The whole turn, well inside iOS's ~30 s for an app-refresh task.
  final Duration deadline;

  /// The lane drain inside the turn.
  final Duration drain;

  /// The rig window's end: past it the turn does no network and the next
  /// request is not submitted.
  final DateTime? until;
  final String lane;

  /// Runs the turn. Returns `{resubmit: bool, ...bg_turn fields}`; never
  /// throws — an error is a journal line and `expired: true`.
  Future<Map<String, Object?>> run({
    required String id,
    required String launchReason,
    required String appState,
    required bool protectedData,
  }) async {
    final begin = _clock().toUtc();
    final fields = <String, Object?>{
      'id': id,
      'launch_reason': launchReason,
      'app_state': appState,
      'protected_data': protectedData,
      'begin': begin.toIso8601String(),
      'lane': lane,
    };
    if (until != null && !begin.isBefore(until!)) {
      fields
        ..['end'] = _clock().toUtc().toIso8601String()
        ..['expired'] = false
        ..['past_until'] = true
        ..['resubmit'] = false;
      journal('bg_turn', fields);
      return fields;
    }
    var expired = false;
    var looked = false;
    var fresh = 0;
    try {
      await Future<void>(() async {
        final s = await service();
        if (s == null) {
          fields['no_service'] = true;
          return;
        }
        await s.load();
        final seen = s.inbox.value.map((r) => r.id).toSet();
        looked = await s.look().timeout(drain, onTimeout: () => false);
        for (final r in s.inbox.value) {
          if (seen.contains(r.id)) continue;
          fresh++;
          final n = await notify(r.id);
          journal('notify_local', <String, Object?>{
            'letter_id': r.id,
            'auth': n.auth,
            'add_err': n.addError,
          });
        }
      }).timeout(deadline);
    } on TimeoutException {
      expired = true;
    } catch (error) {
      fields['error'] = '${error.runtimeType}';
    }
    fields
      ..['end'] = _clock().toUtc().toIso8601String()
      ..['expired'] = expired
      ..['looked'] = looked
      ..['fresh'] = fresh
      ..['resubmit'] = true;
    journal('bg_turn', fields);
    return fields;
  }
}

/// The platform half: the method channel the Swift task handler calls.
abstract final class SealedBackground {
  /// Must match `SealedBackgroundTask.channelName` in AppDelegate.swift.
  static const String channelName =
      'com.tlscodes.reference_app/sealed_background';
  static const MethodChannel _channel = MethodChannel(channelName);

  /// The rig writes the window's end here (UTC ISO), next to the journal.
  static const String untilFile = 'sealed_bg_until';

  static void _journal(String event, Map<String, Object?> fields) {
    try {
      final dir = intelligenceStorageDirectory().path;
      File('$dir/${SealedLetterService.journalName}').writeAsStringSync(
        '${jsonEncode(<String, Object?>{'at': DateTime.now().toUtc().toIso8601String(), 'event': event, ...fields})}\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (_) {
      // The journal is evidence, never a dependency.
    }
  }

  static DateTime? _until() {
    try {
      final f = File('${intelligenceStorageDirectory().path}/$untilFile');
      return f.existsSync()
          ? DateTime.parse(f.readAsStringSync().trim()).toUtc()
          : null;
    } catch (_) {
      return null;
    }
  }

  /// Installs the handler. Call once, before runApp, only when
  /// [kSealedBackground]; [running] hands over the live service when the
  /// engine was suspended with the app's own service in it.
  static void install({required SealedLetterService? Function() running}) {
    if (!kSealedBackground) return;
    SealedLetterService? own;
    _channel.setMethodCallHandler((call) async {
      final a = (call.arguments as Map?)?.cast<String, Object?>() ?? const {};
      switch (call.method) {
        case 'event':
          // Swift-side lines (bg_registered, bg_submitted, bg_cancelled,
          // delivered) go to the same journal.
          _journal(
            '${a['event']}',
            (a['fields'] as Map?)?.cast<String, Object?>() ?? const {},
          );
          return null;
        case 'turn':
          final turn = SealedBackgroundTurn(
            until: _until(),
            journal: _journal,
            service: () async {
              final live = running();
              if (live != null) return live;
              if (own != null) return own;
              // main() boots the identity unawaited; wait for that boot
              // rather than start a second one (the key is first-unlock,
              // so a locked cold launch can still read it).
              for (var i = 0; i < 50 && identityBootPending.value; i++) {
                await Future<void>.delayed(const Duration(milliseconds: 100));
              }
              if (appIdentity == null && !identityBootPending.value) {
                await bootAppIdentity();
              }
              final identity = appIdentity;
              if (identity == null) return null;
              return own = SealedLetterService.disk(
                identity: identity,
                relayHost: defaultBorderRelayHost,
              );
            },
            notify: (letterId) async {
              final r = await _channel.invokeMapMethod<String, Object?>(
                'notify',
                <String, Object?>{'letter_id': letterId},
              );
              return SealedNotifyResult(
                auth: '${r?['auth'] ?? 'unknown'}',
                addError: r?['add_err'] as String?,
              );
            },
          );
          return turn.run(
            id: '${a['id']}',
            launchReason: '${a['launch_reason']}',
            appState: '${a['app_state']}',
            protectedData: a['protected_data'] == true,
          );
      }
      throw MissingPluginException(call.method);
    });
    // Swift held its launch-time lines (bg_registered, bg_submitted) until
    // a handler existed; this asks for them now.
    unawaited(_channel.invokeMethod<void>('ready').catchError((Object _) {}));
  }
}
