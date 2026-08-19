import 'dart:typed_data';

import 'package:broadcast_media/src/compact_news_codec.dart';
import 'package:test/test.dart';

// Identity "brotli" stand-ins: layout, determinism and clean-failure logic are
// proven in pure Dart; real Brotli byte budgets come only from
// tools/phase5/gate_6.sh.
Uint8List _id(Uint8List b) => b;

Map<String, Object?> _page() => {
      'ver': 1,
      'title': 'شبکه‌ی آزمایشی در سه استان',
      'dek': 'پوشش کم‌مصرف برای کنتورها',
      'published': '2026-08-18T14:30:00+03:30',
      'source': 'خبرگزاری نمونه',
      'image': {
        'type': 'blurhash',
        'hash': 'LKO2?U%2Tw=w]~RBVZRi};RPxuwH',
        'w': 32,
        'h': 20,
        'alt': 'دکل کنار مزرعه',
      },
      'body': 'متن خبر با چند جمله‌ی فارسی و یک عدد ۴۲ و emoji 🙂.',
    };

void main() {
  test('CBOR encoding is deterministic and round-trips', () {
    final a = encodeNewsCbor(_page());
    final b = encodeNewsCbor(_page());
    expect(a, b);
    final wire = encodeNewsPage(_page(), _id);
    final back = decodeNewsPage(wire, _id);
    expect(back, _page());
  });

  test('key order is enforced regardless of input map order', () {
    final shuffled = <String, Object?>{};
    final src = _page();
    for (final k in src.keys.toList().reversed) {
      shuffled[k] = src[k];
    }
    expect(encodeNewsCbor(shuffled), encodeNewsCbor(src));
  });

  test('missing key fails cleanly', () {
    final bad = _page()..remove('body');
    expect(() => encodeNewsCbor(bad), throwsA(isA<MalformedNewsPage>()));
  });

  test('malformed wire fails cleanly, never garbage', () {
    expect(
      () => decodeNewsPage(Uint8List.fromList([0xFF, 0x00, 0x01]), _id),
      throwsA(isA<MalformedNewsPage>()),
    );
  });
}
