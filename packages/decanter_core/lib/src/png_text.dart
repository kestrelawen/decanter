import 'dart:convert';
import 'dart:io' show zlib;
import 'dart:typed_data';

/// The 8-byte PNG file signature.
const List<int> pngSignature = <int>[
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
];

/// Text-chunk keywords SillyTavern writes cards into, in **priority order**.
///
/// `ccv3` (Character Card V3) is preferred when a PNG carries both. This order
/// is the one SillyTavern's own `character-card-parser.js` uses; matching it is
/// required for a card that has both chunks to resolve to the same content it
/// does in SillyTavern.
const List<String> tavernCardKeywords = <String>['ccv3', 'chara'];

class PngFormatException implements Exception {
  PngFormatException(this.message);

  final String message;

  @override
  String toString() => 'PngFormatException: $message';
}

/// A decoded text chunk from a PNG (`tEXt`, `zTXt` or `iTXt`).
class PngTextChunk {
  const PngTextChunk({
    required this.type,
    required this.keyword,
    required this.text,
  });

  /// `tEXt`, `zTXt` or `iTXt`.
  final String type;

  /// The chunk keyword, e.g. `chara` or `ccv3`.
  final String keyword;

  /// The decoded text payload.
  final String text;

  @override
  String toString() => 'PngTextChunk($type, "$keyword", ${text.length} chars)';
}

/// Walks a PNG's chunk stream and returns every text chunk it contains.
///
/// Only the chunk framing is parsed — IDAT pixel data is skipped, not decoded,
/// and chunk CRCs are not verified (SillyTavern does not verify them either, and
/// a card with a stale CRC is still readable in every real client).
List<PngTextChunk> readPngTextChunks(Uint8List bytes) {
  if (bytes.length < pngSignature.length) {
    throw PngFormatException(
      'file is ${bytes.length} bytes, shorter than the 8-byte PNG signature',
    );
  }
  for (var i = 0; i < pngSignature.length; i++) {
    if (bytes[i] != pngSignature[i]) {
      throw PngFormatException('not a PNG: signature mismatch at byte $i');
    }
  }

  final chunks = <PngTextChunk>[];
  var offset = pngSignature.length;

  while (offset + 12 <= bytes.length) {
    final length = _readUint32(bytes, offset);
    final type = _readLatin1(bytes, offset + 4, 4);
    final dataStart = offset + 8;

    // Truncated or corrupt framing: stop rather than read out of bounds.
    if (dataStart + length + 4 > bytes.length) break;

    switch (type) {
      case 'tEXt':
        chunks.add(_parseText(bytes, dataStart, length, 'tEXt'));
      case 'zTXt':
        final chunk = _parseZtxt(bytes, dataStart, length);
        if (chunk != null) chunks.add(chunk);
      case 'iTXt':
        final chunk = _parseItxt(bytes, dataStart, length);
        if (chunk != null) chunks.add(chunk);
    }

    offset = dataStart + length + 4;
    if (type == 'IEND') break;
  }

  return chunks;
}

/// Returns the raw text of the highest-priority card chunk present, or null.
String? findCardChunkText(Uint8List bytes) {
  final chunks = readPngTextChunks(bytes);
  for (final keyword in tavernCardKeywords) {
    for (final chunk in chunks) {
      if (chunk.keyword == keyword) return chunk.text;
    }
  }
  return null;
}

/// Decodes the character card embedded in a PNG.
///
/// Returns null when the PNG carries no `chara`/`ccv3` chunk at all. Returns the
/// decoded JSON string otherwise.
String? findCardJsonString(Uint8List bytes) {
  final text = findCardChunkText(bytes);
  if (text == null) return null;
  final trimmed = text.replaceAll(RegExp(r'\s'), '');
  return utf8.decode(base64Decode(trimmed));
}

// --- chunk decoders -------------------------------------------------------

PngTextChunk _parseText(Uint8List b, int start, int length, String type) {
  final end = start + length;
  final nul = _indexOfNul(b, start, end);
  final keyword = _readLatin1(b, start, nul - start);
  // tEXt payload is Latin-1 by spec.
  final text = _readLatin1(b, nul + 1, end - nul - 1);
  return PngTextChunk(type: type, keyword: keyword, text: text);
}

PngTextChunk? _parseZtxt(Uint8List b, int start, int length) {
  final end = start + length;
  final nul = _indexOfNul(b, start, end);
  if (nul + 1 >= end) return null;
  final keyword = _readLatin1(b, start, nul - start);
  final method = b[nul + 1];
  if (method != 0) return null; // only zlib/deflate is defined
  final compressed = Uint8List.sublistView(b, nul + 2, end);
  try {
    return PngTextChunk(
      type: 'zTXt',
      keyword: keyword,
      text: latin1.decode(zlib.decode(compressed)),
    );
  } catch (_) {
    return null; // undecodable payload: skip, don't blow up the import
  }
}

PngTextChunk? _parseItxt(Uint8List b, int start, int length) {
  final end = start + length;
  var cursor = _indexOfNul(b, start, end);
  if (cursor + 2 >= end) return null;
  final keyword = _readLatin1(b, start, cursor - start);

  final compressionFlag = b[cursor + 1];
  // b[cursor + 2] is compressionMethod; only 0 is defined.
  cursor += 3;

  cursor = _skipNullTerminated(b, cursor, end); // language tag
  cursor = _skipNullTerminated(b, cursor, end); // translated keyword
  if (cursor > end) return null;

  final payload = Uint8List.sublistView(b, cursor, end);
  try {
    final data = compressionFlag == 1 ? zlib.decode(payload) : payload;
    return PngTextChunk(
      type: 'iTXt',
      keyword: keyword,
      // iTXt is UTF-8 by spec, unlike tEXt.
      text: utf8.decode(data),
    );
  } catch (_) {
    return null;
  }
}

// --- primitives -----------------------------------------------------------

int _readUint32(Uint8List b, int o) =>
    (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];

String _readLatin1(Uint8List b, int start, int length) {
  if (length <= 0) return '';
  return latin1.decode(Uint8List.sublistView(b, start, start + length));
}

int _indexOfNul(Uint8List b, int start, int end) {
  for (var i = start; i < end; i++) {
    if (b[i] == 0) return i;
  }
  return end;
}

int _skipNullTerminated(Uint8List b, int start, int end) {
  final nul = _indexOfNul(b, start, end);
  return nul >= end ? end + 1 : nul + 1;
}
