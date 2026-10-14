import 'dart:math' as math;

import 'package:decanter_core/decanter_core.dart';
import 'package:test/test.dart';

/// A constant entry, so it activates without any key matching getting in the
/// way of testing where things land.
Map<String, dynamic> lore(
  int uid,
  String content, {
  int position = 0,
  int depth = 4,
  String role = 'system',
  String? outletName,
}) =>
    <String, dynamic>{
      'uid': uid,
      'key': <String>[],
      'content': content,
      'constant': true,
      'position': position,
      'depth': depth,
      'role': role,
      if (outletName != null) 'outletName': outletName,
      if (outletName != null) 'order': 100,
    };

WorldInfoScanResult scanLore(List<Map<String, dynamic>> entries) =>
    WorldInfoScanner(random: math.Random(1)).scan(
      sources: <WorldInfoSource>[
        WorldInfoSource(
          key: 'test',
          book: CharacterBook.fromJson(<String, dynamic>{
            'extensions': <String, dynamic>{},
            'entries': entries,
          }),
        ),
      ],
      history: const <ChatMessage>[],
    );

TavernCard cardOf(Map<String, dynamic> data) => TavernCard.fromJson(
      <String, dynamic>{
        'spec': 'chara_card_v2',
        'spec_version': '2.0',
        'data': data
      },
    );

TavernCard fullCard() => cardOf(<String, dynamic>{
      'name': 'Seraphina',
      'description': 'the description',
      'personality': 'the personality',
      'scenario': 'the scenario',
      'mes_example': 'EXAMPLE DIALOGUE',
      'post_history_instructions': 'POST HISTORY',
    });

List<ChatMessage> turns(List<String> contents) => <ChatMessage>[
      for (var i = 0; i < contents.length; i++)
        ChatMessage(
          role: i.isEven ? ChatRole.user : ChatRole.assistant,
          content: contents[i],
        ),
    ];

void main() {
  group('system block order', () {
    test('follows the documented SillyTavern order', () {
      final prompt = const PromptAssembler().assemble(
        card: fullCard(),
        userName: 'Mara',
        personaDescription: 'persona text',
      );

      expect(prompt.blocks.map((b) => b.id).toList(), <String>[
        'main',
        'charDescription',
        'charPersonality',
        'scenario',
        'personaDescription',
        'dialogueExamples',
        'postHistoryInstructions',
      ]);
    });

    test('lore lands before and after the main prompt, not just anywhere', () {
      final prompt = const PromptAssembler().assemble(
        card: fullCard(),
        lore: scanLore(<Map<String, dynamic>>[
          lore(0, 'BEFORE LORE', position: 0),
          lore(1, 'AFTER LORE', position: 1),
        ]),
      );

      final ids = prompt.blocks.map((b) => b.id).toList();
      expect(ids, <String>[
        'worldInfoBefore',
        'main',
        'worldInfoAfter',
        'charDescription',
        'charPersonality',
        'scenario',
        'dialogueExamples',
        'postHistoryInstructions',
      ]);
    });

    test('empty card fields are omitted rather than sent as blanks', () {
      final prompt = const PromptAssembler().assemble(
        card: cardOf(<String, dynamic>{'name': 'Bare'}),
      );
      // Only the main prompt survives; everything else on this card is empty.
      expect(prompt.blocks.map((b) => b.id).toList(), <String>['main']);
      expect(prompt.messages, hasLength(1));
    });

    test('post-history instructions are sent last, after the chat', () {
      final prompt = const PromptAssembler().assemble(
        card: fullCard(),
        history: turns(<String>['first turn', 'second turn']),
      );
      expect(prompt.messages.last.content, 'POST HISTORY');
    });

    test('an empty post-history block does not eat the example dialogue', () {
      // Regression: an earlier version removed the last message positionally
      // and deleted dialogueExamples when this field was empty.
      final prompt = const PromptAssembler().assemble(
        card: cardOf(<String, dynamic>{
          'name': 'NoPhi',
          'mes_example': 'EXAMPLE DIALOGUE',
        }),
      );
      expect(prompt.blocks.map((b) => b.id), contains('dialogueExamples'));
      expect(prompt.messages.last.content, 'EXAMPLE DIALOGUE');
    });
  });

  group('macros in the prompt', () {
    test('the default main prompt expands char and user', () {
      final prompt = const PromptAssembler().assemble(
        card: fullCard(),
        userName: 'Mara',
      );
      final main = prompt.blocks.firstWhere((b) => b.id == 'main');
      expect(main.content, contains('Seraphina'));
      expect(main.content, contains('Mara'));
      expect(main.content, isNot(contains('{{')));
    });

    test("a character's own system prompt overrides the default", () {
      final prompt = const PromptAssembler().assemble(
        card: cardOf(<String, dynamic>{
          'name': 'Override',
          'system_prompt': 'CUSTOM SYSTEM PROMPT',
        }),
      );
      final main = prompt.blocks.firstWhere((b) => b.id == 'main');
      expect(main.content, 'CUSTOM SYSTEM PROMPT');
    });

    test('lore injected at depth has its macros expanded', () {
      final prompt = const PromptAssembler().assemble(
        card: fullCard(),
        userName: 'Mara',
        lore: scanLore(<Map<String, dynamic>>[
          lore(0, 'Hello {{user}}, meet {{char}}.', position: 4, depth: 1),
        ]),
      );
      expect(
        prompt.messages.map((m) => m.content),
        contains('Hello Mara, meet Seraphina.'),
      );
    });

    test('history messages have their macros expanded', () {
      final prompt = const PromptAssembler().assemble(
        card: fullCard(),
        userName: 'Mara',
        history: <ChatMessage>[
          ChatMessage(
            role: ChatRole.assistant,
            content: '*{{char}} looks at {{user}}.*',
          ),
          ChatMessage(
            role: ChatRole.user,
            content: 'Hello {{char}}, I am {{user}}.',
          ),
        ],
      );
      expect(
        prompt.messages.map((m) => m.content),
        contains('*Seraphina looks at Mara.*'),
      );
      expect(
        prompt.messages.map((m) => m.content),
        contains('Hello Seraphina, I am Mara.'),
      );
    });
  });

  group('history', () {
    test('is appended in order after the system area', () {
      final prompt = const PromptAssembler().assemble(
        card: fullCard(),
        history: turns(<String>['one', 'two', 'three']),
      );
      final contents = prompt.messages.map((m) => m.content).toList();
      expect(contents.indexOf('one'), lessThan(contents.indexOf('two')));
      expect(contents.indexOf('two'), lessThan(contents.indexOf('three')));
    });

    test('depth lore lands inside the history, counting from the end', () {
      final prompt = const PromptAssembler().assemble(
        card: fullCard(),
        history: turns(<String>['m1', 'm2', 'm3']),
        lore: scanLore(<Map<String, dynamic>>[
          lore(0, 'DEPTH LORE', position: 4, depth: 1),
        ]),
      );

      final contents = prompt.messages.map((m) => m.content).toList();
      final at = contents.indexOf('DEPTH LORE');
      expect(at, greaterThan(-1));
      // depth 1 means immediately before the newest message.
      expect(contents[at - 1], 'm2');
      expect(contents[at + 1], 'm3');
    });

    test('depth 0 lore lands after the newest message', () {
      final prompt = const PromptAssembler().assemble(
        card: fullCard(),
        history: turns(<String>['m1', 'm2']),
        lore: scanLore(<Map<String, dynamic>>[
          lore(0, 'TAIL LORE', position: 4, depth: 0),
        ]),
      );
      final contents = prompt.messages.map((m) => m.content).toList();
      // m2, then the injection, then post-history instructions.
      expect(contents[contents.indexOf('m2') + 1], 'TAIL LORE');
    });

    test('an atDepth entry uses its own role', () {
      final prompt = const PromptAssembler().assemble(
        card: fullCard(),
        history: turns(<String>['m1']),
        lore: scanLore(<Map<String, dynamic>>[
          lore(0, 'USER ROLE LORE', position: 4, depth: 1, role: 'user'),
        ]),
      );
      final injected = prompt.messages.firstWhere(
        (m) => m.content == 'USER ROLE LORE',
      );
      expect(injected.role, ChatRole.user);
      expect(injected.isSystemNote, isTrue);
    });
  });

  group("author's note", () {
    test('is injected at the configured depth', () {
      final prompt = const PromptAssembler().assemble(
        card: fullCard(),
        history: turns(<String>['m1', 'm2', 'm3']),
        authorNote: 'STAY IN CHARACTER',
        authorNoteDepth: 2,
      );
      final contents = prompt.messages.map((m) => m.content).toList();
      final at = contents.indexOf('STAY IN CHARACTER');
      expect(at, greaterThan(-1));
      expect(contents[at + 1], 'm2');
      expect(contents[at + 2], 'm3');
    });

    test('AN Top and AN Bottom lore are folded into the note', () {
      final prompt = const PromptAssembler().assemble(
        card: fullCard(),
        history: turns(<String>['m1']),
        authorNote: 'NOTE',
        lore: scanLore(<Map<String, dynamic>>[
          lore(0, 'TOP', position: 2),
          lore(1, 'BOTTOM', position: 3),
        ]),
      );
      final note = prompt.messages.firstWhere(
        (m) => m.content.contains('NOTE'),
      );
      expect(note.content, 'TOP\nNOTE\nBOTTOM');
    });

    test('no note means nothing is injected', () {
      final prompt = const PromptAssembler().assemble(
        card: fullCard(),
        history: turns(<String>['m1']),
      );
      expect(prompt.blocks.map((b) => b.id), isNot(contains('authorsNote')));
    });
  });

  group('example message anchors', () {
    test('EM Top and EM Bottom wrap the example dialogue', () {
      final prompt = const PromptAssembler().assemble(
        card: fullCard(),
        lore: scanLore(<Map<String, dynamic>>[
          lore(0, 'EM TOP', position: 5),
          lore(1, 'EM BOTTOM', position: 6),
        ]),
      );
      final examples = prompt.blocks.firstWhere(
        (b) => b.id == 'dialogueExamples',
      );
      expect(examples.content, 'EM TOP\nEXAMPLE DIALOGUE\nEM BOTTOM');
    });
  });

  group('outlets', () {
    test('outlet entries are collected and not injected on their own', () {
      final prompt = const PromptAssembler().assemble(
        card: fullCard(),
        lore: scanLore(<Map<String, dynamic>>[
          lore(0, 'RAIN AND FOG', position: 7, outletName: 'Weather'),
        ]),
      );

      expect(prompt.outlets['Weather'], 'RAIN AND FOG');
      // Nothing was injected into the message list for it.
      for (final message in prompt.messages) {
        expect(message.content, isNot(contains('RAIN AND FOG')));
      }
    });

    test('{{outlet::Name}} pulls an outlet into a prompt block', () {
      final prompt = const PromptAssembler().assemble(
        card: cardOf(<String, dynamic>{
          'name': 'OutletUser',
          'system_prompt': 'Current weather: {{outlet::Weather}}',
        }),
        lore: scanLore(<Map<String, dynamic>>[
          lore(0, 'RAIN AND FOG', position: 7, outletName: 'Weather'),
        ]),
      );
      final main = prompt.blocks.firstWhere((b) => b.id == 'main');
      expect(main.content, 'Current weather: RAIN AND FOG');
    });
  });

  group('context budget', () {
    test('the oldest history is dropped first', () {
      final prompt = const PromptAssembler(
        tokenizer: WordTokenizer(),
      ).assemble(
        // No system text at all, so the budget applies purely to history.
        card: cardOf(<String, dynamic>{'name': 'Bare'}),
        templates: const PromptTemplates(mainPrompt: ''),
        history: turns(<String>['a', 'b', 'c', 'd', 'e']),
        contextBudget: 2,
      );

      expect(prompt.droppedForBudget.map((m) => m.content).toList(), <String>[
        'a',
        'b',
        'c',
      ]);
      expect(
          prompt.messages.map((m) => m.content).toList(), <String>['d', 'e']);
      expect(prompt.tokenCost, 2);
    });

    test('a zero budget keeps everything', () {
      final prompt = const PromptAssembler().assemble(
        card: fullCard(),
        history: turns(<String>['a', 'b', 'c']),
        contextBudget: 0,
      );
      expect(prompt.droppedForBudget, isEmpty);
      expect(prompt.messages.map((m) => m.content),
          containsAll(<String>['a', 'b', 'c']));
    });
  });

  group('inspection', () {
    test('every message is a system, user or assistant turn', () {
      final prompt = const PromptAssembler().assemble(
        card: fullCard(),
        history: turns(<String>['m1', 'm2']),
        authorNote: 'NOTE',
      );
      for (final message in prompt.messages) {
        expect(ChatRole.values, contains(message.role));
        expect(message.content.trim(), isNotEmpty);
      }
    });

    test('debugSummary reports the shape', () {
      final prompt = const PromptAssembler().assemble(
        card: fullCard(),
        history: turns(<String>['m1']),
      );
      expect(prompt.debugSummary, contains('messages'));
      expect(prompt.debugSummary, contains('blocks'));
      expect(prompt.isEmpty, isFalse);
    });
  });
}
