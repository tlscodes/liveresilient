/// Reports whether [value] contains any ASCII control character.
///
/// A code unit is a control character when it is strictly below `0x20`
/// (the space character) — the full C0 range, including tab (`0x09`) and
/// newline (`0x0A`) — or when it is exactly `0x7F` (DEL). The boundary is
/// `< 0x20`, not `<= 0x20`: `0x20` (space) itself is not flagged.
///
/// Operates on UTF-16 code units (Dart's native [String] representation),
/// not code points. Ordinary text — plain Farsi/English, emoji, and the
/// individual surrogate halves of an astral-plane emoji's surrogate pair —
/// is always `>= 0x20` and `!= 0x7F`, so none of it is flagged; only actual
/// control bytes are.
///
/// Used to reject control bytes (e.g. terminal escape sequences) in
/// free-text fields that cross the wire, such as hangup/give-up reasons.
bool containsControlCharacters(String value) {
  for (final codeUnit in value.codeUnits) {
    if (codeUnit < 0x20 || codeUnit == 0x7f) {
      return true;
    }
  }
  return false;
}
