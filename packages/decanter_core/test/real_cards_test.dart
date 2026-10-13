import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:decanter_core/decanter_core.dart';
import 'package:test/test.dart';

/// Regression tests against files shipped by SillyTavern itself.
///
/// Synthetic fixtures prove the parser matches the spec; these prove it matches
/// what the real application actually writes. They are skipped rather than
/// failed when the fixtures are absent, so a checkout without them still runs.
void main() {
  final png = File('testdata/real/default_Seraphina.png');
  final lorebook = File('testdata/real/Eldoria.json');

  group('real SillyTavern card', () {
    test('carries both card chunks and prefers ccv3', () {
      if (!png.existsSync()) {
        markTestSkipped('fixture missing: ${png.path}');
        return;
      }
      final bytes = Uint8List.fromList(png.readAsBytesSync());
      final keywords = readPngTextChunks(bytes).map((c) => c.keyword).toList();

      expect(keywords, contains('chara'));
      expect(keywords, contains('ccv3'));
      expect(findCardChunkText(bytes), isNotNull);
    });

    test('parses as a V3 card with its metadata intact', () {
      if (!png.existsSync()) {
        markTestSkipped('fixture missing: ${png.path}');
        return;
      }
      final card = TavernCard.fromPng(
        Uint8List.fromList(png.readAsBytesSync()),
      );

      expect(card.spec, CardSpec.v3);
      expect(card.specVersion, '3.0');
      expect(card.name, 'Seraphina');
      expect(card.creator, isNotEmpty);
      expect(card.firstMes, isNotEmpty);
      expect(card.description, isNotEmpty);

      // The card links a world by name; that link must survive parsing.
      expect(card.linkedWorldName, 'Eldoria');
      expect(card.extensions.keys, contains('world'));
    });

    test('exposes the embedded character book', () {
      if (!png.existsSync()) {
        markTestSkipped('fixture missing: ${png.path}');
        return;
      }
      final card = TavernCard.fromPng(
        Uint8List.fromList(png.readAsBytesSync()),
      );

      final book = card.characterBook;
      expect(book, isNotNull);
      expect(book!.name, 'Eldoria');
      expect(book.entries, isNotEmpty);
      expect(book.active, isNotEmpty);

      // Every entry must have keys and content to be usable at all.
      for (final entry in book.entries) {
        expect(entry.content, isNotEmpty);
      }
      expect(
        book.entries.expand((e) => e.keys),
        contains('eldoria'),
      );
    });

    test('a V3 field this version does not model is preserved, not dropped',
        () {
      if (!png.existsSync()) {
        markTestSkipped('fixture missing: ${png.path}');
        return;
      }
      final card = TavernCard.fromPng(
        Uint8List.fromList(png.readAsBytesSync()),
      );

      // `group_only_greetings` is real V3 data; capturing it in dataExtras is
      // what keeps a re-export lossless.
      expect(card.dataExtras, contains('group_only_greetings'));
      final reExported = card.toJson();
      final data = reExported['data'] as Map<String, dynamic>;
      expect(data, contains('group_only_greetings'));
      expect(data['name'], 'Seraphina');
    });
  });

  group('real SillyTavern lorebook', () {
    test('loads as a native world-info file', () {
      if (!lorebook.existsSync()) {
        markTestSkipped('fixture missing: ${lorebook.path}');
        return;
      }
      final json = jsonDecode(lorebook.readAsStringSync()) as Map;
      final book =
          CharacterBook.fromNativeJson(Map<String, dynamic>.from(json));

      expect(book.entries, hasLength(4));
      expect(book.active, hasLength(4));

      final allKeys = book.entries.expand((e) => e.keys).toList();
      expect(allKeys, contains('eldoria'));
      expect(allKeys, contains('magical forest'));

      // uids in this file are the entry keys, as strings.
      expect(book.entries.map((e) => e.uid).toList(), <int>[0, 1, 2, 3]);
    });

    test('every entry round-trips without losing its uid', () {
      if (!lorebook.existsSync()) {
        markTestSkipped('fixture missing: ${lorebook.path}');
        return;
      }
      final json = jsonDecode(lorebook.readAsStringSync()) as Map;
      final book =
          CharacterBook.fromNativeJson(Map<String, dynamic>.from(json));

      final out = book.toJson();
      final entries = out['entries'] as List<dynamic>;
      expect(entries, hasLength(4));
      for (var i = 0; i < 4; i++) {
        expect((entries[i] as Map)['uid'], i);
      }
    });
  });

  group('lorebook engine against the real card', () {
    /// The scanner is pure, so a real card plus a real message is a full
    /// end-to-end check of activation on data the actual app produced.
    WorldInfoScanResult scan(String message) {
      final card = TavernCard.fromPng(
        Uint8List.fromList(png.readAsBytesSync()),
      );
      return WorldInfoScanner(random: math.Random(7)).scan(
        sources: <WorldInfoSource>[
          WorldInfoSource(key: 'character', book: card.characterBook!),
        ],
        history: <ChatMessage>[
          ChatMessage(role: ChatRole.user, content: message),
        ],
      );
    }

    test('lore activates when a message names it', () {
      if (!png.existsSync()) {
        markTestSkipped('fixture missing: ${png.path}');
        return;
      }
      final result = scan('we push deeper into the magical forest');
      final comment = <String>[for (final e in result.activated) e.comment];

      expect(comment, contains('eldoria'));

      // `magic` is a plain substring of `magical`, and this book leaves
      // matchWholeWords unset, so the power entry fires as well. That is
      // faithful to the file — pinning it here so nobody "fixes" it by
      // switching on whole-word matching and silently changing what the
      // author's lorebook does.
      expect(comment, contains('power'));

      expect(result.at(WorldInfoPosition.beforeChar), hasLength(2));
      expect(result.tokenCost, greaterThan(0));
    });

    test('an unrelated message activates nothing', () {
      if (!png.existsSync()) {
        markTestSkipped('fixture missing: ${png.path}');
        return;
      }
      final result = scan('the kettle boiled over');
      expect(result.activated, isEmpty);
      expect(result.tokenCost, 0);
    });

    test('the activated lore is real text from the card', () {
      if (!png.existsSync()) {
        markTestSkipped('fixture missing: ${png.path}');
        return;
      }
      final result = scan('we push deeper into the magical forest');
      for (final entry in result.activated) {
        expect(entry.content.trim(), isNotEmpty);
      }
      expect(result.activated.map((e) => e.keys), everyElement(isNotEmpty));
    });
  });
}
