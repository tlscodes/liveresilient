/// The relay seam: two immutable lookups and two writes.
///
/// This is intentionally the whole surface. A relay in this design does
/// not authenticate, does not order, does not deduplicate semantically,
/// and cannot alter what it carries — so a volunteer operator adds
/// reach without adding trust, and the client code is identical whether
/// it is talking to a hosted worker, a file on disk, or bytes that
/// arrived on a memory card.
library;

import 'dart:typed_data';

import 'broadcast_address.dart';
import 'broadcast_ids.dart';

/// Storage and retrieval of immutable broadcast bytes.
abstract interface class BroadcastRelay {
  /// A short label for logs and for telling readers which relay answered.
  String get name;

  /// The descriptor at [address], or null if this relay has not seen it.
  Future<Uint8List?> fetchDescriptor(DescriptorAddress address);

  /// The object named by [address], or null.
  Future<Uint8List?> fetchObject(ObjectAddress address);

  /// Store a descriptor at [address].
  Future<void> putDescriptor(DescriptorAddress address, Uint8List encoded);

  /// Store an object under the hash of its own [bytes].
  Future<void> putObject(Uint8List bytes);
}

/// An in-process relay: the reference implementation, and the one the
/// tests run against.
///
/// It enforces the two invariants a real relay must also enforce, so a
/// bug in either shows up here first: an object is filed under the hash
/// of its own bytes, and a descriptor address is never overwritten with
/// different bytes. That second rule is what makes a fork visible
/// instead of silently replacing history.
class InMemoryBroadcastRelay implements BroadcastRelay {
  InMemoryBroadcastRelay({this.name = 'memory'});

  @override
  final String name;

  final Map<String, Uint8List> _objects = {};
  final Map<String, Uint8List> _descriptors = {};

  /// Number of objects held.
  int get objectCount => _objects.length;

  /// Number of descriptor slots held.
  int get descriptorCount => _descriptors.length;

  @override
  Future<Uint8List?> fetchDescriptor(DescriptorAddress address) async {
    final held = _descriptors[address.path];
    return held == null ? null : Uint8List.fromList(held);
  }

  @override
  Future<Uint8List?> fetchObject(ObjectAddress address) async {
    final held = _objects[address.path];
    return held == null ? null : Uint8List.fromList(held);
  }

  @override
  Future<void> putDescriptor(
    DescriptorAddress address,
    Uint8List encoded,
  ) async {
    final existing = _descriptors[address.path];
    if (existing != null && !bytesEqual(existing, encoded)) {
      throw StateError(
        'refusing to replace the descriptor at ${address.path}: '
        'an immutable address may not change',
      );
    }
    _descriptors[address.path] = Uint8List.fromList(encoded);
  }

  @override
  Future<void> putObject(Uint8List bytes) async {
    final hash = contentHash(bytes);
    _objects[ObjectAddress(hash).path] = Uint8List.fromList(bytes);
  }

  /// Drop everything. Retention is a relay policy, and short retention is
  /// the intended one: a relay is a cache, and durability comes from the
  /// readers who already hold verified copies.
  void clear() {
    _objects.clear();
    _descriptors.clear();
  }

  /// Drop one object, to model a relay that has expired or been made to
  /// remove it. Readers must survive this, which is what the tests check.
  bool dropObject(Uint8List hash) =>
      _objects.remove(ObjectAddress(hash).path) != null;
}
