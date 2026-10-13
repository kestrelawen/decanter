import 'dart:math' as math;

import 'package:decanter_core/decanter_core.dart';
import 'package:test/test.dart';

void main() {
  group('built-in macros', () {
    TavernCard card() => TavernCard.fromJson(<String, dynamic>{
          'spec': 'chara_card_v2',
          'data': <String, dynamic>{
            'name': 'Seraphina',
            'description': 'a curious researcher',
            'personality': 'warm, stubborn',
            'scenario': 'a flooded laboratory',
            'first_mes': 'You wake up.',
            'mes_example': '<START>Seraphina: hello',
            'creator': 'OtisAlejandro',
            'character_version': '1.0.0',
          },
        });

    MacroExpander expander({String? original}) => MacroExpander(
          context: MacroContext(
            charName: 'Seraphina',
            userName: 'Mara',
            card: card(),
            personaDescription: 'a tired cartographer',
            original: original,
          ),
          random: math.Random(1),
        );

    test('substitutes char and user', () {
      expect(
        expander().expand('{{char}} greets {{user}}.'),
        'Seraphina greets Mara.',
      );
    });

    test('substitutes the card fields', () {
      final out = expander().expand(
        '{{description}}|{{personality}}|{{scenario}}|'
        '{{first_mes}}|{{mes_example}}|{{creator}}|{{charversion}}',
      );
      expect(out, contains('a curious researcher'));
      expect(out, contains('warm, stubborn'));
      expect(out, contains('a flooded laboratory'));
      expect(out, contains('You wake up.'));
      expect(out, contains('<START>Seraphina: hello'));
      expect(out, contains('OtisAlejandro'));
      expect(out, contains('1.0.0'));
    });

    test('substitutes the persona', () {
      expect(expander().expand('{{persona}}'), 'a tired cartographer');
    });

    test('{{original}} inserts the original, then expands macros inside it',
        () {
      final e = expander(original: 'Write {{char}} next.');
      // Expansion runs multiple passes so nested macros resolve. The original
      // is inserted textually, so macros inside it expand the same way they
      // would in SillyTavern's final prompt.
      expect(e.expand('Wrap: {{original}}'), 'Wrap: Write Seraphina next.');
    });

    test('{{original}} with no macros is inserted verbatim', () {
      final e = expander(original: 'plain original');
      expect(e.expand('X {{original}} Y'), 'X plain original Y');
    });

    test('{{newline}} becomes a newline', () {
      expect(expander().expand('a{{newline}}b'), 'a\nb');
    });

    test('{{random:}} picks one of the options', () {
      final out = expander().expand('{{random:red,green,blue}}');
      expect(<String>['red', 'green', 'blue'], contains(out));
    });

    test('{{roll:}} stays inside the dice range', () {
      final e = expander();
      for (var i = 0; i < 50; i++) {
        final roll = int.parse(e.expand('{{roll:1d20}}'));
        expect(roll, inInclusiveRange(1, 20));
      }
    });

    test('{{roll:2d6+3}} respects its modifier range', () {
      final e = expander();
      for (var i = 0; i < 50; i++) {
        final roll = int.parse(e.expand('{{roll:2d6+3}}'));
        expect(roll, inInclusiveRange(5, 15));
      }
    });
  });

  group('unknown and tricky macros', () {
    MacroExpander expander({Map<String, String> extra = const {}}) =>
        MacroExpander(
          context: MacroContext(
            charName: 'Char',
            userName: 'User',
            extra: extra,
          ),
          random: math.Random(1),
        );

    test('an unknown macro is left verbatim, not blanked', () {
      // Silently destroying it would hide a typo; SillyTavern leaves it too.
      expect(expander().expand('a {{nope}} b'), 'a {{nope}} b');
    });

    test('a malformed roll is left verbatim', () {
      expect(expander().expand('{{roll:banana}}'), '{{roll:banana}}');
    });

    test('an out-of-range dice expression is refused', () {
      expect(expander().expand('{{roll:9999d9999}}'), '{{roll:9999d9999}}');
    });

    test('caller macros override built-ins', () {
      final e = expander(extra: <String, String>{'char': 'Override'});
      expect(e.expand('{{char}}'), 'Override');
    });

    test('text with no macros is returned untouched', () {
      expect(expander().expand('plain text'), 'plain text');
    });

    test('a self-referential macro terminates instead of looping', () {
      final e = expander(extra: <String, String>{'loop': '{{loop}}'});
      expect(e.expand('{{loop}}'), '{{loop}}');
    });

    test('expandAll expands every entry', () {
      final e = expander();
      expect(
        e.expandAll(<String>['{{char}}', 'no macro', '{{user}}']),
        <String>['Char', 'no macro', 'User'],
      );
    });
  });
}
