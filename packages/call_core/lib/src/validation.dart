bool containsControlCharacters(String value) {
  for (final codeUnit in value.codeUnits) {
    if (codeUnit < 0x20 || codeUnit == 0x7f) {
      return true;
    }
  }
  return false;
}
