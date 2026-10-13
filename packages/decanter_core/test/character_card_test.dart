import 'package:decanter_core/decanter_core.dart';
import 'package:test/test.dart';

void main() {
  group('V1 legacy cards', () {
    test('a document with no spec is treated as V1 and hoisted', () {
      final card = TavernCard.fromJson(<String, dynamic>{
        'name': 'Legacy',
        'description': 'old style',
        'personality': 'grumpy',
        'scenario': 'a cave',
        'first_mes': 'Who goes there?',
        'mes_example': '<START>',
      });

      expect(card.spec, CardSpec.v1);
      expect(card.name, 'Legacy');
      expect(card.personality, 'grumpy');
      expect(card.firstMes, 'Who goes there?');
      // V1 has no alternates, so greetings is just the first message.
      expect(card.greetings, <String>['Who goes there?']);
    });

    test('an explicit chara_card_v1 spec is also V1', () {
      final card = TavernCard.fromJson(<String, dynamic>{
        'spec': 'chara_card_v1',
        'name': 'Explicit',
      });
      expect(card.spec, CardSpec.v1);
      expect(card.name, 'Explicit');
    });
  });

  group('V2 cards', () {
    Map<String, dynamic> fullCard() => <String, dynamic>{
          'spec': 'chara_card_v2',
          'spec_version': '2.0',
          'data': <String, dynamic>{
            'name': 'Seraphina',
            'description': 'A test character.',
            'personality': 'curious',
            'scenario': 'a laboratory',
            'first_mes': 'Hello there.',
            'mes_example': '<START>',
            'creator_notes': 'notes',
            'system_prompt': 'sys prompt',
            'post_history_instructions': 'post',
            'alternate_greetings': <String>['Alt one.', 'Alt two.'],
            'tags': <String>['sci-fi', 'test'],
            'creator': 'someone',
            'character_version': '1.2',
            'extensions': <String, dynamic>{'world': 'TestWorld'},
          },
        };

    test('reads every V2 field', () {
      final card = TavernCard.fromJson(fullCard());
      expect(card.spec, CardSpec.v2);
      expect(card.specVersion, '2.0');
      expect(card.name, 'Seraphina');
      expect(card.creatorNotes, 'notes');
      expect(card.systemPrompt, 'sys prompt');
      expect(card.postHistoryInstructions, 'post');
      expect(card.alternateGreetings, <String>['Alt one.', 'Alt two.']);
      expect(card.tags, <String>['sci-fi', 'test']);
      expect(card.creator, 'someone');
      expect(card.characterVersion, '1.2');
    });

    test('greetings is the first message followed by the alternates', () {
      final card = TavernCard.fromJson(fullCard());
      expect(card.greetings, <String>[
        'Hello there.',
        'Alt one.',
        'Alt two.',
      ]);
    });

    test('a bare-string alternate_greetings becomes a one-element list', () {
      final json = fullCard();
      (json['data'] as Map<String, dynamic>)['alternate_greetings'] =
          'Only one alt.';
      final card = TavernCard.fromJson(json);
      expect(card.alternateGreetings, <String>['Only one alt.']);
    });

    test('exposes the world linked through extensions', () {
      final card = TavernCard.fromJson(fullCard());
      expect(card.linkedWorldName, 'TestWorld');
    });

    test('a v2 deck with no data object is rejected', () {
      expect(
        () => TavernCard.fromJson(<String, dynamic>{
          'spec': 'chara_card_v2',
          'spec_version': '2.0',
        }),
        throwsA(isA<CardFormatException>()),
      );
    });

    test('a non-object payload is rejected', () {
      expect(
        () => TavernCard.fromJson(
            <String, dynamic>{'spec': 'chara_card_v2', 'data': 'nope'}),
        throwsA(isA<CardFormatException>()),
      );
    });
  });

  group('V3 cards', () {
    test('parses and keeps unmodelled V3 keys', () {
      final card = TavernCard.fromJson(<String, dynamic>{
        'spec': 'chara_card_v3',
        'spec_version': '3.0',
        'data': <String, dynamic>{
          'name': 'V3Char',
          'description': 'v3 description',
          'nickname': 'V3',
          'creator_notes_multilingual': <String, dynamic>{'en': 'notes'},
          'assets': <dynamic>[
            <String, dynamic>{
              'type': 'icon',
              'uri': 'embeded://assets/icon/main.png',
            },
          ],
          'extensions': <String, dynamic>{},
        },
      });

      expect(card.spec, CardSpec.v3);
      expect(card.name, 'V3Char');
      expect(card.specVersion, '3.0');

      // The spec requires unknown keys never be destroyed — the partial V3 spec
      // knowledge on this end is exactly why dataExtras exists.
      expect(card.dataExtras['nickname'], 'V3');
      expect(card.dataExtras['assets'], isA<List<dynamic>>());
      expect(card.dataExtras['creator_notes_multilingual'], isA<Map>());
    });
  });

  group('round-trip', () {
    test('unmodelled keys survive a parse/serialise cycle', () {
      final original = <String, dynamic>{
        'spec': 'chara_card_v3',
        'spec_version': '3.0',
        'data': <String, dynamic>{
          'name': 'RoundTrip',
          'description': 'd',
          'nickname': 'RT',
          'source': <dynamic>['https://example.com/card'],
          'group_only_greetings': <dynamic>['group greeting'],
          'extensions': <String, dynamic>{
            'vendor': <String, dynamic>{'x': 1}
          },
        },
      };

      final out = TavernCard.fromJson(original).toJson();
      final data = out['data'] as Map<String, dynamic>;

      expect(out['spec'], 'chara_card_v2');
      expect(data['name'], 'RoundTrip');
      expect(data['nickname'], 'RT');
      expect(data['source'], <dynamic>['https://example.com/card']);
      expect(data['group_only_greetings'], <dynamic>['group greeting']);
      expect((data['extensions'] as Map)['vendor'], <String, dynamic>{'x': 1});
    });

    test('known fields are not duplicated by the extras map', () {
      final out = TavernCard.fromJson(<String, dynamic>{
        'spec': 'chara_card_v2',
        'data': <String, dynamic>{
          'name': 'Dup',
          'alternate_greetings': <String>['a', 'b'],
          'tags': <String>['t'],
        },
      }).toJson();

      final data = out['data'] as Map<String, dynamic>;
      expect(data['alternate_greetings'], <String>['a', 'b']);
      expect(data['tags'], <String>['t']);
      // dataExtras must not have re-introduced them as raw duplicates.
      expect(data.containsKey('spec'), isFalse);
      expect(data.containsKey('spec_version'), isFalse);
    });

    test('a V1 card serialises as a V2 document', () {
      final out = TavernCard.fromJson(<String, dynamic>{
        'name': 'Upgrade',
        'description': 'd',
        'first_mes': 'hi',
      }).toJson();

      expect(out['spec'], 'chara_card_v2');
      expect(out['spec_version'], '1.0');
      final data = out['data'] as Map<String, dynamic>;
      expect(data['name'], 'Upgrade');
      expect(data['first_mes'], 'hi');
    });
  });
}
