// The relay's shelves in memory, for tests that have no network (a widget
// test replaces HttpClient). One list of boxes per direction, read forward
// from a count like the real shelf, with a switch for "out of reach".
import 'dart:typed_data';

import 'package:reference_app/src/sealed/pair_shelf.dart';

class MemoryRelay {
  /// `from>to` -> every box put there, in order.
  final Map<String, List<Uint8List>> shelves = <String, List<Uint8List>>{};

  /// Nothing can be put and nothing read.
  bool down = false;

  int puts = 0;

  /// Every look that was made, in order.
  final List<ShelfLook> looks = <ShelfLook>[];

  /// The shelf as the install [own] sees it.
  LetterShelf shelfOf(String own) => _MemoryShelf(this, own);
}

class _MemoryShelf implements LetterShelf {
  _MemoryShelf(this._relay, this._own);

  final MemoryRelay _relay;
  final String _own;

  @override
  final Map<String, int> cursors = <String, int>{};

  @override
  Future<bool> put(String peerInstall, Uint8List box) async {
    if (_relay.down) return false;
    _relay.puts++;
    (_relay.shelves['$_own>$peerInstall'] ??= <Uint8List>[]).add(box);
    return true;
  }

  @override
  Future<List<Uint8List>?> collect(
    String peerInstall, {
    ShelfLook look = ShelfLook.all,
  }) async {
    if (_relay.down) return null;
    _relay.looks.add(look);
    final key = '$peerInstall>$_own';
    final held = _relay.shelves[key] ?? const <Uint8List>[];
    final from = cursors['in:$key'] ?? 0;
    if (from >= held.length) return <Uint8List>[];
    cursors['in:$key'] = held.length;
    return held.sublist(from);
  }
}
