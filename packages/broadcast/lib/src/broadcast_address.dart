/// Addressing: how a reader names what it wants before it has it.
///
/// Every address here is immutable and predictable. There is no "latest"
/// endpoint, because a mutable pointer would be the one thing in this
/// design that cannot be cached and therefore the one thing worth
/// blocking. A reader that holds post `n` asks for `n + 1` by name; an
/// empty answer means "not published yet", not "ask somewhere else".
library;

import 'dart:typed_data';

import 'broadcast_ids.dart';

/// Cache directive for every response a relay serves from these paths.
///
/// Sound only because the paths are immutable: a given (author, seq) is
/// one document forever, and a given object hash is its own bytes. This
/// is what separates read volume from relay cost — a million readers of
/// one post are a million edge hits, not a million origin requests.
const String immutableCacheControl = 'public, max-age=31536000, immutable';

/// Highest sequence number the wire format can express.
const int maxSeq = 0xFFFFFFFF;

/// Where a descriptor lives.
class DescriptorAddress {
  const DescriptorAddress({required this.authorId, required this.seq});

  final Uint8List authorId;
  final int seq;

  /// Relay path for this descriptor.
  String get path => '/a/${hexEncode(authorId)}/$seq';

  /// The address of the next post by the same author.
  ///
  /// Returns null at the top of the sequence space rather than wrapping,
  /// because wrapping would let a chain quietly restart at genesis.
  DescriptorAddress? get next => seq >= maxSeq
      ? null
      : DescriptorAddress(authorId: authorId, seq: seq + 1);

  /// Parse a path produced by [path].
  static DescriptorAddress? tryParse(String path) {
    final parts = path.split('/');
    // A well-formed path splits to ['', 'a', '<hex>', '<seq>'].
    if (parts.length != 4 || parts[0].isNotEmpty || parts[1] != 'a') {
      return null;
    }
    if (parts[2].length != authorIdBytes * 2) return null;
    final Uint8List authorId;
    try {
      authorId = hexDecode(parts[2]);
    } on FormatException {
      return null;
    }
    final seq = int.tryParse(parts[3]);
    // Reject a leading zero or a plus sign: two spellings of one address
    // would split the cache and let the same post be served twice.
    if (seq == null || seq < 0 || seq > maxSeq || '$seq' != parts[3]) {
      return null;
    }
    return DescriptorAddress(authorId: authorId, seq: seq);
  }

  @override
  bool operator ==(Object other) =>
      other is DescriptorAddress &&
      other.seq == seq &&
      bytesEqual(other.authorId, authorId);

  @override
  int get hashCode => Object.hash(hexEncode(authorId), seq);

  @override
  String toString() => path;
}

/// Where a content-addressed object lives.
class ObjectAddress {
  ObjectAddress(this.hash) {
    if (hash.length != hashBytes) {
      throw ArgumentError.value(
        hash.length,
        'hash.length',
        'a content hash is $hashBytes bytes',
      );
    }
  }

  final Uint8List hash;

  /// Relay path for this object.
  String get path => '/o/${hexEncode(hash)}';

  /// Parse a path produced by [path].
  static ObjectAddress? tryParse(String path) {
    final parts = path.split('/');
    if (parts.length != 3 || parts[0].isNotEmpty || parts[1] != 'o') {
      return null;
    }
    if (parts[2].length != hashBytes * 2) return null;
    try {
      return ObjectAddress(hexDecode(parts[2]));
    } on FormatException {
      return null;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is ObjectAddress && bytesEqual(other.hash, hash);

  @override
  int get hashCode => hexEncode(hash).hashCode;

  @override
  String toString() => path;
}
