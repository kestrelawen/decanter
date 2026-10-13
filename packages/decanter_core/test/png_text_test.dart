import 'dart:convert';
import 'dart:typed_data';

import 'package:decanter_core/decanter_core.dart';
import 'package:test/test.dart';

import 'png_builder.dart';

Map<String, dynamic> _v2Card({String name = 'Seraphina'}) => <String, dynamic>{
      'spec': 'chara_card_v2',
      'spec_version': '2.0',
      'data': <String, dynamic>{
        'name': name,
        'description': 'A test character.',
        'personality': 'curious',
        'scenario': 'a laboratory',
        'first_mes': 'Hello there.',
        'mes_example': '<START>',
        'creator_notes': 'notes',
        'system_prompt': 'sys',
        'post_history_instructions': 'phi',
        'alternate_greetings': <String>['Alt one.', 'Alt two.'],
        'tags': <String>['test'],
        'creator': 'someone',
        'character_version': '1.2',
        'extensions': <String, dynamic>{'world': 'TestWorld'},
      },
    };

void main() {
  group('PNG chunk reading', () {
    test('finds a tEXt chunk and its payload', () {
      final png = buildPng(<Uint8List>[textChunk('Comment', 'hello')]);
      final chunks = readPngTextChunks(png);
      expect(chunks, hasLength(1));
      expect(chunks.single.type, 'tEXt');
      expect(chunks.single.keyword, 'Comment');
      expect(chunks.single.text, 'hello');
    });

    test('decodes a compressed zTXt chunk', () {
      final png = buildPng(<Uint8List>[
        ztxtChunk('chara', base64.encode(utf8.encode(jsonEncode(_v2Card())))),
      ]);
      final chunks = readPngTextChunks(png);
      expect(chunks.single.type, 'zTXt');
      expect(chunks.single.keyword, 'chara');
      final decoded = jsonDecode(utf8.decode(base64Decode(chunks.single.text)));
      expect(decoded['spec'], 'chara_card_v2');
    });

    test('rejects a file that is not a PNG', () {
      final notPng = Uint8List.fromList(List<int>.filled(64, 0x41));
      expect(
        () => readPngTextChunks(notPng),
        throwsA(isA<PngFormatException>()),
      );
    });

    test('rejects a file shorter than the signature', () {
      expect(
        () => readPngTextChunks(Uint8List.fromList(<int>[0x89, 0x50])),
        throwsA(isA<PngFormatException>()),
      );
    });

    test('a truncated chunk stops the walk instead of throwing', () {
      final full = buildPng(<Uint8List>[textChunk('chara', 'x')]);
      final truncated = Uint8List.sublistView(full, 0, full.length - 10);
      expect(() => readPngTextChunks(truncated), returnsNormally);
    });
  });

  group('card chunk priority', () {
    test('prefers ccv3 over chara regardless of file order', () {
      final v2 = cardChunk('chara', _v2Card(name: 'FromV2'));
      final v3 = cardChunk(
        'ccv3',
        <String, dynamic>{
          'spec': 'chara_card_v3',
          'spec_version': '3.0',
          'data': <String, dynamic>{'name': 'FromV3', 'description': 'v3'},
        },
      );

      for (final chunks in <List<Uint8List>>[
        <Uint8List>[v2, v3],
        <Uint8List>[v3, v2],
      ]) {
        final card = TavernCard.fromPng(buildPng(chunks));
        expect(card.name, 'FromV3');
        expect(card.spec, CardSpec.v3);
      }
    });

    test('falls back to chara when there is no ccv3', () {
      final card = TavernCard.fromPng(
        buildPng(<Uint8List>[cardChunk('chara', _v2Card(name: 'OnlyV2'))]),
      );
      expect(card.name, 'OnlyV2');
      expect(card.spec, CardSpec.v2);
    });

    test('a PNG with no card chunk yields null, not an empty card', () {
      final png = buildPng(<Uint8List>[textChunk('Comment', 'just a picture')]);
      expect(findCardJsonString(png), isNull);
      expect(
        () => TavernCard.fromPng(png),
        throwsA(
          isA<CardFormatException>().having(
            (e) => e.message,
            'message',
            contains('no character card chunk'),
          ),
        ),
      );
    });

    test('a corrupt base64 payload reports a card format error', () {
      final png = buildPng(<Uint8List>[textChunk('chara', '!!!not base64!!!')]);
      expect(
        () => TavernCard.fromPng(png),
        throwsA(isA<CardFormatException>()),
      );
    });
  });
}
