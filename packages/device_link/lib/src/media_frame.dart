import 'dart:collection';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

String generateMeshMessageId() {
  final random = Random.secure();
  final bytes = List<int>.generate(
    16,
    (_) => random.nextInt(256),
    growable: false,
  );

  return base64Url.encode(bytes).replaceAll('=', '');
}

class MediaFrame {
  final int version;
  final String messageId;
  final String originKeyId;
  final String currentRelayKeyId;

  final int createdAtMs;
  final int expiresAtMs;

  final int maxHops;
  final int hopCount;

  final Uint8List ciphertext;
  final Uint8List signature;

  MediaFrame({
    this.version = 1,
    required this.messageId,
    required this.originKeyId,
    required this.currentRelayKeyId,
    required this.createdAtMs,
    required this.expiresAtMs,
    required this.maxHops,
    required this.hopCount,
    required List<int> ciphertext,
    required List<int> signature,
  }) : ciphertext = Uint8List.fromList(ciphertext),
       signature = Uint8List.fromList(signature);

  bool isExpiredAt(int nowMs) => nowMs >= expiresAtMs;

  bool get canBeForwarded => hopCount < maxHops;
}

/// The implementation must verify the origin signature and every relay
/// transition. Cryptography must be implemented using an audited library,
/// not custom hash/signature code.
abstract interface class MediaFrameAuthenticator {
  Future<bool> verify(MediaFrame envelope);

  /// Returns a new authenticated envelope with hopCount incremented.
  Future<MediaFrame> createForwardedEnvelope(MediaFrame envelope);
}

abstract interface class MeshBroadcaster {
  Future<void> broadcast(MediaFrame envelope);
}

enum MeshDisposition {
  delivered,
  deliveredAndForwarded,
  duplicate,
  expired,
  invalid,
  hopLimitReached,
  rejected,
}

class MeshSeenCache {
  final int maximumEntries;

  final LinkedHashMap<String, int> _expiresByMessageId =
      LinkedHashMap<String, int>();

  MeshSeenCache({this.maximumEntries = 8192}) : assert(maximumEntries > 0);

  /// Returns true when the message ID has not been seen.
  bool markIfNew({
    required String messageId,
    required int expiresAtMs,
    required int nowMs,
  }) {
    _purgeExpired(nowMs);

    final existingExpiry = _expiresByMessageId[messageId];

    if (existingExpiry != null && existingExpiry > nowMs) {
      return false;
    }

    _expiresByMessageId.remove(messageId);
    _expiresByMessageId[messageId] = expiresAtMs;

    while (_expiresByMessageId.length > maximumEntries) {
      _expiresByMessageId.remove(_expiresByMessageId.keys.first);
    }

    return true;
  }

  void _purgeExpired(int nowMs) {
    final expired = <String>[];

    for (final entry in _expiresByMessageId.entries) {
      if (entry.value <= nowMs) {
        expired.add(entry.key);
      }
    }

    for (final messageId in expired) {
      _expiresByMessageId.remove(messageId);
    }
  }
}

class MeshMessageProcessor {
  final MediaFrameAuthenticator authenticator;
  final MeshBroadcaster broadcaster;
  final MeshSeenCache seenCache;

  final bool forwardingEnabled;
  final int maximumLifetimeMs;
  final int maximumAllowedHops;

  final Future<void> Function(MediaFrame envelope) onDeliver;

  MeshMessageProcessor({
    required this.authenticator,
    required this.broadcaster,
    required this.seenCache,
    required this.onDeliver,
    this.forwardingEnabled = false,
    this.maximumLifetimeMs = 10 * 60 * 1000,
    this.maximumAllowedHops = 8,
  });

  Future<MeshDisposition> process(
    MediaFrame envelope, {
    required int nowMs,
  }) async {
    if (!_hasValidBounds(envelope, nowMs)) {
      return MeshDisposition.rejected;
    }

    if (envelope.isExpiredAt(nowMs)) {
      return MeshDisposition.expired;
    }

    // Invalid frames are not delivered or forwarded.
    if (!await authenticator.verify(envelope)) {
      return MeshDisposition.invalid;
    }

    final isNew = seenCache.markIfNew(
      messageId: envelope.messageId,
      expiresAtMs: envelope.expiresAtMs,
      nowMs: nowMs,
    );

    if (!isNew) {
      return MeshDisposition.duplicate;
    }

    await onDeliver(envelope);

    if (!forwardingEnabled) {
      return MeshDisposition.delivered;
    }

    if (!envelope.canBeForwarded) {
      return MeshDisposition.hopLimitReached;
    }

    final forwarded = await authenticator.createForwardedEnvelope(envelope);

    if (forwarded.hopCount != envelope.hopCount + 1 ||
        forwarded.maxHops != envelope.maxHops ||
        forwarded.messageId != envelope.messageId ||
        forwarded.expiresAtMs != envelope.expiresAtMs) {
      throw StateError(
        'Authenticator produced an invalid forwarding transition.',
      );
    }

    await broadcaster.broadcast(forwarded);

    return MeshDisposition.deliveredAndForwarded;
  }

  bool _hasValidBounds(MediaFrame envelope, int nowMs) {
    if (envelope.version != 1 ||
        envelope.messageId.isEmpty ||
        envelope.originKeyId.isEmpty ||
        envelope.currentRelayKeyId.isEmpty) {
      return false;
    }

    // Two-sided sanity bound on createdAtMs relative to nowMs, checked
    // before any arithmetic touches it: a crafted extreme value (e.g.
    // 64-bit int min) must never reach the lifetime subtraction below,
    // where `expiresAtMs - createdAtMs` can silently wrap around 64-bit
    // signed overflow and evade the maximumLifetimeMs check entirely
    // (found by fuzzing — see
    // packages/device_link/test/parser_robustness_test.dart, target
    // `mesh_frame`). Any legitimate frame already satisfies this: a
    // non-expired frame has expiresAtMs > nowMs and expiresAtMs <=
    // createdAtMs + maximumLifetimeMs, so createdAtMs > nowMs -
    // maximumLifetimeMs follows from the (overflow-safe) checks below.
    if (envelope.createdAtMs > nowMs + 60 * 1000 ||
        envelope.createdAtMs < nowMs - maximumLifetimeMs - 60 * 1000) {
      return false;
    }

    if (envelope.expiresAtMs <= envelope.createdAtMs) {
      return false;
    }

    if (envelope.expiresAtMs - envelope.createdAtMs > maximumLifetimeMs) {
      return false;
    }

    if (envelope.maxHops < 0 ||
        envelope.maxHops > maximumAllowedHops ||
        envelope.hopCount < 0 ||
        envelope.hopCount > envelope.maxHops) {
      return false;
    }

    return true;
  }
}
