import 'package:flutter_test/flutter_test.dart';
import 'package:reference_app/src/mp4_probe.dart';

List<int> _u16(int v) => [(v >> 8) & 0xFF, v & 0xFF];
List<int> _u32(int v) => [
  (v >> 24) & 0xFF,
  (v >> 16) & 0xFF,
  (v >> 8) & 0xFF,
  v & 0xFF,
];
List<int> _u64(int v) => [..._u32(v >> 32), ..._u32(v & 0xFFFFFFFF)];

/// A box with a 32-bit size header.
List<int> box(String type, List<int> body) => [
  ..._u32(body.length + 8),
  ...type.codeUnits,
  ...body,
];

/// A box with size == 1 and a 64-bit largesize header.
List<int> largeBox(String type, List<int> body) => [
  ..._u32(1),
  ...type.codeUnits,
  ..._u64(body.length + 16),
  ...body,
];

/// The identity matrix every mvhd/tkhd carries (36 bytes).
List<int> get _matrix => [
  ..._u32(0x00010000),
  ..._u32(0),
  ..._u32(0),
  ..._u32(0),
  ..._u32(0x00010000),
  ..._u32(0),
  ..._u32(0),
  ..._u32(0),
  ..._u32(0x40000000),
];

List<int> mvhd({
  required int version,
  required int timescale,
  required int duration,
}) {
  final stamp = version == 0 ? _u32(0) : _u64(0);
  return box('mvhd', [
    version,
    0,
    0,
    0,
    ...stamp, // creation
    ...stamp, // modification
    ..._u32(timescale),
    ...(version == 0 ? _u32(duration) : _u64(duration)),
    ..._u32(0x00010000), // rate
    ..._u16(0x0100), // volume
    ...List<int>.filled(10, 0), // reserved
    ..._matrix,
    ...List<int>.filled(24, 0), // pre_defined
    ..._u32(3), // next_track_ID
  ]);
}

List<int> tkhd({
  required int version,
  required int width,
  required int height,
}) {
  final stamp = version == 0 ? _u32(0) : _u64(0);
  return box('tkhd', [
    version,
    0,
    0,
    7,
    ...stamp, // creation
    ...stamp, // modification
    ..._u32(1), // track_ID
    ..._u32(0), // reserved
    ...(version == 0 ? _u32(4000) : _u64(4000)), // duration
    ...List<int>.filled(8, 0), // reserved
    ..._u16(0), // layer
    ..._u16(0), // alternate_group
    ..._u16(0), // volume
    ..._u16(0), // reserved
    ..._matrix,
    ..._u32(width << 16),
    ..._u32(height << 16),
  ]);
}

List<int> trak(List<int> tkhdBox) => box('trak', tkhdBox);

List<int> ftyp(String brand) => box('ftyp', [
  ...brand.codeUnits,
  ..._u32(0x200),
  ...'isomiso2mp41'.codeUnits,
]);

void main() {
  group('probeMp4', () {
    test(
      'version-0 headers: clock from mvhd, size from the first video trak',
      () {
        final bytes = [
          ...ftyp('isom'),
          ...box('free', List<int>.filled(8, 0)),
          ...box('mdat', List<int>.filled(100, 0xAB)),
          ...box('moov', [
            ...mvhd(version: 0, timescale: 1000, duration: 4000),
            ...trak(tkhd(version: 0, width: 0, height: 0)),
            ...trak(tkhd(version: 0, width: 320, height: 240)),
          ]),
        ];
        final info = probeMp4(bytes);
        expect(info, isNotNull);
        expect(info!.brand, 'isom');
        expect(info.durationMs, 4000);
        expect(info.width, 320);
        expect(info.height, 240);
      },
    );

    test('version-1 headers land on the wider offsets', () {
      final bytes = [
        ...ftyp('mp42'),
        ...box('moov', [
          ...mvhd(version: 1, timescale: 90000, duration: 360000),
          ...trak(tkhd(version: 1, width: 0, height: 0)),
          ...trak(tkhd(version: 1, width: 320, height: 240)),
        ]),
      ];
      final info = probeMp4(bytes);
      expect(info, isNotNull);
      expect(info!.brand, 'mp42');
      expect(info.durationMs, 4000);
      expect(info.width, 320);
      expect(info.height, 240);
    });

    test('a 64-bit largesize moov header is walked the same way', () {
      final bytes = [
        ...ftyp('isom'),
        ...largeBox('moov', [
          ...mvhd(version: 0, timescale: 600, duration: 1500),
          ...trak(tkhd(version: 0, width: 1920, height: 1080)),
        ]),
      ];
      final info = probeMp4(bytes);
      expect(info, isNotNull);
      expect(info!.durationMs, 2500);
      expect(info.width, 1920);
      expect(info.height, 1080);
    });

    test('audio-only movie reports 0x0 but keeps its clock', () {
      final bytes = [
        ...ftyp('isom'),
        ...box('moov', [
          ...mvhd(version: 0, timescale: 44100, duration: 88200),
          ...trak(tkhd(version: 0, width: 0, height: 0)),
        ]),
      ];
      final info = probeMp4(bytes)!;
      expect(info.durationMs, 2000);
      expect(info.width, 0);
      expect(info.height, 0);
    });

    test('missing moov, missing mvhd, missing ftyp return null', () {
      expect(
        probeMp4([...ftyp('isom'), ...box('mdat', List<int>.filled(16, 0))]),
        isNull,
      );
      expect(
        probeMp4([
          ...ftyp('isom'),
          ...box('moov', trak(tkhd(version: 0, width: 320, height: 240))),
        ]),
        isNull,
      );
      expect(
        probeMp4(box('moov', mvhd(version: 0, timescale: 1000, duration: 1))),
        isNull,
      );
    });

    test('garbage and truncated files return null', () {
      expect(probeMp4(const []), isNull);
      expect(probeMp4(List<int>.filled(7, 0)), isNull);
      expect(probeMp4(List<int>.generate(64, (i) => (i * 37) & 0xFF)), isNull);
      final good = [
        ...ftyp('isom'),
        ...box('moov', [
          ...mvhd(version: 0, timescale: 1000, duration: 4000),
          ...trak(tkhd(version: 0, width: 320, height: 240)),
        ]),
      ];
      expect(probeMp4(good.sublist(0, 40)), isNull, reason: 'moov cut off');
      expect(
        probeMp4(good.sublist(0, good.length - 50)),
        isNull,
        reason: 'moov overruns',
      );
      final zeroTimescale = [
        ...ftyp('isom'),
        ...box('moov', mvhd(version: 0, timescale: 0, duration: 4000)),
      ];
      expect(probeMp4(zeroTimescale), isNull);
    });
  });
}
