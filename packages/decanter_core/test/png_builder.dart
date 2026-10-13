/// Builds real, structurally valid PNG byte streams for tests.
///
/// A hand-rolled PNG rather than a fixture so the parser is exercised against
/// genuine chunk framing — correct lengths and real CRC-32s — instead of a
/// hand-waved byte array that happens to sit in the right order.
library;

import 'dart:convert';
import 'dart:io' show zlib;
import 'dart:typed_data';

final List<int> _crcTable = _buildCrcTable();

List<int> _buildCrcTable() {
  final table = List<int>.filled(256, 0);
  for (var n = 0; n < 256; n++) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
    }
    table[n] = c;
  }
  return table;
}

int _crc32(List<int> bytes) {
  var c = 0xFFFFFFFF;
  for (final b in bytes) {
    c = _crcTable[(c ^ b) & 0xFF] ^ (c >> 8);
  }
  return c ^ 0xFFFFFFFF;
}

Uint8List _chunk(String type, List<int> data) {
  final typeBytes = ascii.encode(type);
  final out = BytesBuilder();
  out.add((ByteData(4)..setUint32(0, data.length)).buffer.asUint8List());
  out.add(typeBytes);
  out.add(data);
  out.add(
    (ByteData(4)..setUint32(0, _crc32(<int>[...typeBytes, ...data])))
        .buffer
        .asUint8List(),
  );
  return out.toBytes();
}

/// A 1x1 RGBA image header, so the file is a real PNG and not just chunks.
Uint8List _ihdr() {
  final data = ByteData(13);
  data.setUint32(0, 1); // width
  data.setUint32(4, 1); // height
  data.setUint8(8, 8); // bit depth
  data.setUint8(9, 6); // colour type: truecolour with alpha
  data.setUint8(10, 0); // compression
  data.setUint8(11, 0); // filter
  data.setUint8(12, 0); // interlace
  return _chunk('IHDR', data.buffer.asUint8List());
}

/// One zlib-compressed scanline (filter byte + one RGBA pixel).
Uint8List _idat() => _chunk('IDAT', zlib.encode(<int>[0, 0, 0, 0, 255]));

/// A `tEXt` chunk in the Latin-1 encoding the spec requires there.
Uint8List textChunk(String keyword, String text) {
  final data = <int>[...latin1.encode(keyword), 0, ...latin1.encode(text)];
  return _chunk('tEXt', data);
}

/// A `zTXt` chunk: keyword, method byte 0, then zlib-compressed Latin-1 text.
Uint8List ztxtChunk(String keyword, String text) {
  final data = <int>[
    ...latin1.encode(keyword),
    0,
    0,
    ...zlib.encode(latin1.encode(text)),
  ];
  return _chunk('zTXt', data);
}

/// A `tEXt` chunk carrying a base64-encoded UTF-8 JSON card, as
/// SillyTavern writes it.
Uint8List cardChunk(String keyword, Map<String, dynamic> card) {
  return textChunk(keyword, base64.encode(utf8.encode(jsonEncode(card))));
}

/// Assembles chunks into a complete PNG.
Uint8List buildPng(List<Uint8List> chunks) {
  final out = BytesBuilder();
  out.add(<int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  out.add(_ihdr());
  for (final c in chunks) {
    out.add(c);
  }
  out.add(_idat());
  out.add(_chunk('IEND', <int>[]));
  return out.toBytes();
}
