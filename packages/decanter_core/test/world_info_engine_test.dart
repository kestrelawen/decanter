import 'dart:math' as math;

import 'package:decanter_core/decanter_core.dart';
import 'package:test/test.dart';

/// Builds a raw world-info entry map, so the tests exercise the same parsing
/// path real files take rather than a constructor shortcut.
Map<String, dynamic> rawEntry({
  int uid = 0,
  List<String> keys = const <String>[],
  List<String> secondary = const <String>[],
  String content = 'entry content',
  bool constant = false,
  bool selective = false,
  SelectiveLogic logic = SelectiveLogic.andAny,
  bool caseSensitive = false,
  bool wholeWords = false,
  bool regex = false,
  int order = 100,
  int position = 0,
  int probability = 100,
  bool useProbability = true,
  int scanDepth = 2,
  bool enabled = true,
  String? group,
  int? groupWeight,
  int sticky = 0,
  int cooldown = 0,
  int delay = 0,
  bool excludeRecursion = false,
}) =>
    <String, dynamic>{
      'uid': uid,
      'key': keys,
      'keysecondary': secondary,
      'content': content,
      'constant': constant,
      'selective': selective,
      'selectiveLogic': logic.wire,
      'caseSensitive': caseSensitive,
      'matchWholeWords': wholeWords,
      'useRegex': regex,
      'order': order,
      'position': position,
      'probability': probability,
      'useProbability': useProbability,
      'scanDepth': scanDepth,
      'disable': !enabled,
      'sticky': sticky,
      'cooldown': cooldown,
      'delay': delay,
      'excludeRecursion': excludeRecursion,
      if (group != null) 'group': group,
      if (groupWeight != null) 'groupWeight': groupWeight,
    };

CharacterBook bookOf(
  List<Map<String, dynamic>> entries, {
  bool recursive = false,
}) =>
    CharacterBook.fromJson(<String, dynamic>{
      'recursive_scanning': recursive,
      'extensions': <String, dynamic>{},
      'entries': entries,
    });

WorldInfoSource sourceOf(
  List<Map<String, dynamic>> entries, {
  String key = 'test',
  bool recursive = false,
}) =>
    WorldInfoSource(key: key, book: bookOf(entries, recursive: recursive));

List<ChatMessage> said(String text) => <ChatMessage>[
      ChatMessage(role: ChatRole.user, content: text),
    ];

void main() {
  late WorldInfoScanner scanner;

  setUp(() {
    // Fixed seed so probability-driven behaviour is reproducible.
    scanner = WorldInfoScanner(random: math.Random(12345));
  });

  WorldInfoScanResult scan({
    required List<WorldInfoSource> sources,
    List<ChatMessage> history = const <ChatMessage>[],
    WorldInfoTiming? timing,
    String extra = '',
    int tokenBudget = 0,
    int recursionDepth = 1,
    Tokenizer? tokenizer,
  }) {
    final engine = tokenizer == null
        ? scanner
        : WorldInfoScanner(tokenizer: tokenizer, random: math.Random(12345));
    return engine.scan(
      sources: sources,
      history: history,
      timing: timing,
      scan: extra,
      tokenBudget: tokenBudget,
      recursionDepth: recursionDepth,
    );
  }

  group('basic activation', () {
    test('a constant entry activates with no keys and no match', () {
      final result = scan(
        sources: <WorldInfoSource>[
          sourceOf(<Map<String, dynamic>>[rawEntry(constant: true)]),
        ],
      );
      expect(result.activated, hasLength(1));
    });

    test('a key match activates', () {
      final result = scan(
        sources: <WorldInfoSource>[
          sourceOf(<Map<String, dynamic>>[
            rawEntry(keys: <String>['eldoria']),
          ]),
        ],
        history: said('we walk into eldoria at dusk'),
      );
      expect(result.activated, hasLength(1));
    });

    test('no match means nothing activates', () {
      final result = scan(
        sources: <WorldInfoSource>[
          sourceOf(<Map<String, dynamic>>[
            rawEntry(keys: <String>['eldoria']),
          ]),
        ],
        history: said('nothing relevant here'),
      );
      expect(result.activated, isEmpty);
      expect(result.isEmpty, isTrue);
    });

    test('an entry with no keys and not constant never activates', () {
      final result = scan(
        sources: <WorldInfoSource>[
          sourceOf(<Map<String, dynamic>>[rawEntry()])
        ],
        history: said('entry content'),
      );
      expect(result.activated, isEmpty);
    });

    test('a disabled entry never activates', () {
      final result = scan(
        sources: <WorldInfoSource>[
          sourceOf(<Map<String, dynamic>>[
            rawEntry(keys: <String>['eldoria'], enabled: false),
          ]),
        ],
        history: said('eldoria'),
      );
      expect(result.activated, isEmpty);
    });

    test('an enabled entry with blank content never activates', () {
      final result = scan(
        sources: <WorldInfoSource>[
          sourceOf(<Map<String, dynamic>>[
            rawEntry(keys: <String>['eldoria'], content: '   '),
          ]),
        ],
        history: said('eldoria'),
      );
      expect(result.activated, isEmpty);
    });

    test('the extra scan surface participates in matching', () {
      final result = scan(
        sources: <WorldInfoSource>[
          sourceOf(<Map<String, dynamic>>[
            rawEntry(keys: <String>['cartographer']),
          ]),
        ],
        extra: 'the user is a cartographer by trade',
      );
      expect(result.activated, hasLength(1));
    });
  });

  group('matching rules', () {
    test('matching is case-insensitive by default', () {
      final result = scan(
        sources: <WorldInfoSource>[
          sourceOf(<Map<String, dynamic>>[
            rawEntry(keys: <String>['eldoria']),
          ]),
        ],
        history: said('ELDORIA'),
      );
      expect(result.activated, hasLength(1));
    });

    test('caseSensitive is honoured when set', () {
      final result = scan(
        sources: <WorldInfoSource>[
          sourceOf(<Map<String, dynamic>>[
            rawEntry(keys: <String>['eldoria'], caseSensitive: true),
          ]),
        ],
        history: said('ELDORIA'),
      );
      expect(result.activated, isEmpty);
    });

    test('matchWholeWords does not fire on a longer word', () {
      final result = scan(
        sources: <WorldInfoSource>[
          sourceOf(<Map<String, dynamic>>[
            rawEntry(keys: <String>['wood'], wholeWords: true),
          ]),
        ],
        history: said('the wooden door'),
      );
      expect(result.activated, isEmpty);
    });

    test('matchWholeWords fires on the exact word', () {
      final result = scan(
        sources: <WorldInfoSource>[
          sourceOf(<Map<String, dynamic>>[
            rawEntry(keys: <String>['wood'], wholeWords: true),
          ]),
        ],
        history: said('a wood here'),
      );
      expect(result.activated, hasLength(1));
    });

    test('regex keys match as patterns', () {
      final result = scan(
        sources: <WorldInfoSource>[
          sourceOf(<Map<String, dynamic>>[
            rawEntry(keys: <String>[r'eld[oO]ria'], regex: true),
          ]),
        ],
        history: said('we reached eldOria'),
      );
      expect(result.activated, hasLength(1));
    });

    test('an invalid regex does not take down the scan', () {
      final result = scan(
        sources: <WorldInfoSource>[
          sourceOf(<Map<String, dynamic>>[
            rawEntry(keys: <String>['[unclosed'], regex: true),
          ]),
        ],
        history: said('anything'),
      );
      expect(result.activated, isEmpty);
    });
  });

  group('scan depth', () {
    test('only the most recent N messages are searched', () {
      final history = <ChatMessage>[
        ChatMessage(
            role: ChatRole.user, content: 'eldoria was mentioned early'),
        ChatMessage(role: ChatRole.assistant, content: 'later message'),
        ChatMessage(role: ChatRole.user, content: 'newest message'),
      ];

      final shallow = scan(
        sources: <WorldInfoSource>[
          sourceOf(<Map<String, dynamic>>[
            rawEntry(keys: <String>['eldoria'], scanDepth: 1),
          ]),
        ],
        history: history,
      );
      expect(shallow.activated, isEmpty);

      final deep = scan(
        sources: <WorldInfoSource>[
          sourceOf(<Map<String, dynamic>>[
            rawEntry(keys: <String>['eldoria'], scanDepth: 3),
          ]),
        ],
        history: history,
      );
      expect(deep.activated, hasLength(1));
    });
  });

  group('secondary keys and selective logic', () {
    test('andAny requires at least one secondary match', () {
      final sources = <WorldInfoSource>[
        sourceOf(<Map<String, dynamic>>[
          rawEntry(
            keys: <String>['mara'],
            secondary: <String>['revolver'],
            selective: true,
          ),
        ]),
      ];

      expect(
        scan(sources: sources, history: said('mara walked in')).activated,
        isEmpty,
      );
      expect(
        scan(
          sources: sources,
          history: said('mara raised the revolver'),
        ).activated,
        hasLength(1),
      );
    });

    test('notAny blocks when a secondary key is present', () {
      final sources = <WorldInfoSource>[
        sourceOf(<Map<String, dynamic>>[
          rawEntry(
            keys: <String>['mara'],
            secondary: <String>['safe'],
            selective: true,
            logic: SelectiveLogic.notAny,
          ),
        ]),
      ];

      expect(
        scan(sources: sources, history: said('mara is here')).activated,
        hasLength(1),
      );
      expect(
        scan(sources: sources, history: said('mara is safe')).activated,
        isEmpty,
      );
    });

    test('andAll requires every secondary key', () {
      final sources = <WorldInfoSource>[
        sourceOf(<Map<String, dynamic>>[
          rawEntry(
            keys: <String>['mara'],
            secondary: <String>['revolver', 'night'],
            selective: true,
            logic: SelectiveLogic.andAll,
          ),
        ]),
      ];

      expect(
        scan(sources: sources, history: said('mara revolver')).activated,
        isEmpty,
      );
      expect(
        scan(
          sources: sources,
          history: said('mara revolver at night'),
        ).activated,
        hasLength(1),
      );
    });

    test('secondary keys are ignored when selective is false', () {
      final result = scan(
        sources: <WorldInfoSource>[
          sourceOf(<Map<String, dynamic>>[
            rawEntry(
              keys: <String>['mara'],
              secondary: <String>['nothing-here'],
              selective: false,
            ),
          ]),
        ],
        history: said('mara arrived'),
      );
      expect(result.activated, hasLength(1));
    });
  });

  group('probability', () {
    test('probability 100 always fires', () {
      final result = scan(
        sources: <WorldInfoSource>[
          sourceOf(<Map<String, dynamic>>[
            rawEntry(keys: <String>['x'], probability: 100),
          ]),
        ],
        history: said('x'),
      );
      expect(result.activated, hasLength(1));
    });

    test('probability 0 never fires', () {
      final result = scan(
        sources: <WorldInfoSource>[
          sourceOf(<Map<String, dynamic>>[
            rawEntry(keys: <String>['x'], probability: 0),
          ]),
        ],
        history: said('x'),
      );
      expect(result.activated, isEmpty);
    });

    test('useProbability false ignores the probability field', () {
      final result = scan(
        sources: <WorldInfoSource>[
          sourceOf(<Map<String, dynamic>>[
            rawEntry(
                keys: <String>['x'], probability: 0, useProbability: false),
          ]),
        ],
        history: said('x'),
      );
      expect(result.activated, hasLength(1));
    });
  });

  group('inclusion groups', () {
    test('the highest groupWeight wins and the rest are reported', () {
      final result = scan(
        sources: <WorldInfoSource>[
          sourceOf(<Map<String, dynamic>>[
            rawEntry(
              uid: 0,
              keys: <String>['x'],
              content: 'low',
              group: 'weather',
              groupWeight: 10,
            ),
            rawEntry(
              uid: 1,
              keys: <String>['x'],
              content: 'high',
              group: 'weather',
              groupWeight: 90,
            ),
          ]),
        ],
        history: said('x'),
      );

      expect(result.activated, hasLength(1));
      expect(result.activated.single.content, 'high');
      expect(result.droppedByGroup, hasLength(1));
      expect(result.droppedByGroup.single.content, 'low');
    });

    test('entries in different groups do not compete', () {
      final result = scan(
        sources: <WorldInfoSource>[
          sourceOf(<Map<String, dynamic>>[
            rawEntry(uid: 0, keys: <String>['x'], group: 'a'),
            rawEntry(uid: 1, keys: <String>['x'], group: 'b'),
          ]),
        ],
        history: said('x'),
      );
      expect(result.activated, hasLength(2));
    });
  });

  group('budget', () {
    test('lower insertion order wins and the overflow is reported', () {
      final result = scan(
        sources: <WorldInfoSource>[
          sourceOf(<Map<String, dynamic>>[
            rawEntry(
              uid: 0,
              keys: <String>['x'],
              content: 'alpha beta',
              order: 10,
            ),
            rawEntry(
              uid: 1,
              keys: <String>['x'],
              content: 'gamma delta',
              order: 20,
            ),
          ]),
        ],
        history: said('x'),
        tokenBudget: 3,
        tokenizer: const WordTokenizer(),
      );

      expect(result.activated, hasLength(1));
      expect(result.activated.single.content, 'alpha beta');
      expect(result.tokenCost, 2);
      expect(result.excludedByBudget, hasLength(1));
    });

    test('a zero budget means unlimited', () {
      final result = scan(
        sources: <WorldInfoSource>[
          sourceOf(<Map<String, dynamic>>[
            for (var i = 0; i < 10; i++)
              rawEntry(uid: i, keys: <String>['x'], content: 'word$i'),
          ]),
        ],
        history: said('x'),
        tokenBudget: 0,
        tokenizer: const WordTokenizer(),
      );
      expect(result.activated, hasLength(10));
      expect(result.excludedByBudget, isEmpty);
      expect(result.tokenCost, 10);
    });
  });

  group('timed effects', () {
    test('sticky keeps an entry alive, then it expires', () {
      final timing = WorldInfoTiming();
      final sources = <WorldInfoSource>[
        sourceOf(<Map<String, dynamic>>[
          rawEntry(keys: <String>['x'], content: 'sticky lore', sticky: 2),
        ]),
      ];

      // Turn 1: fires by key match.
      final first = scan(
        sources: sources,
        history: said('x'),
        timing: timing,
      );
      expect(first.activated, hasLength(1));
      expect(timing['test:0'].stickyLeft, 2);

      // Turns 2 and 3: no key match, still active, window shrinking.
      for (final remaining in <int>[1, 0]) {
        final carried = scan(
          sources: sources,
          history: said('nothing'),
          timing: timing,
        );
        expect(carried.activated, hasLength(1),
            reason: 'should still be sticky');
        expect(timing['test:0'].stickyLeft, remaining);
      }

      // Turn 4: the window is spent, so the entry needs its key again.
      final expired = scan(
        sources: sources,
        history: said('nothing'),
        timing: timing,
      );
      expect(expired.activated, isEmpty);
    });

    test('a sticky entry does not extend its own window', () {
      final timing = WorldInfoTiming();
      final sources = <WorldInfoSource>[
        sourceOf(<Map<String, dynamic>>[
          rawEntry(keys: <String>['x'], sticky: 1),
        ]),
      ];

      scan(sources: sources, history: said('x'), timing: timing);
      expect(timing['test:0'].stickyLeft, 1);

      // Should burn down, not re-arm to 1 forever.
      scan(sources: sources, history: said('nothing'), timing: timing);
      expect(timing['test:0'].stickyLeft, 0);
    });

    test('cooldown blocks re-activation for its duration', () {
      final timing = WorldInfoTiming();
      final sources = <WorldInfoSource>[
        sourceOf(<Map<String, dynamic>>[
          rawEntry(keys: <String>['x'], cooldown: 2),
        ]),
      ];

      expect(
        scan(sources: sources, history: said('x'), timing: timing).activated,
        hasLength(1),
      );
      // Blocked for two messages.
      for (var i = 0; i < 2; i++) {
        expect(
          scan(
            sources: sources,
            history: said('x'),
            timing: timing,
          ).activated,
          isEmpty,
          reason: 'cooling down',
        );
      }
      // Free again.
      expect(
        scan(sources: sources, history: said('x'), timing: timing).activated,
        hasLength(1),
      );
    });

    test('delay holds an entry out until its window passes', () {
      final timing = WorldInfoTiming();
      timing['test:0'].delayLeft = 2;

      final sources = <WorldInfoSource>[
        sourceOf(<Map<String, dynamic>>[
          rawEntry(keys: <String>['x']),
        ]),
      ];

      for (var i = 0; i < 2; i++) {
        expect(
          scan(
            sources: sources,
            history: said('x'),
            timing: timing,
          ).activated,
          isEmpty,
          reason: 'still delayed',
        );
      }
      expect(
        scan(sources: sources, history: said('x'), timing: timing).activated,
        hasLength(1),
      );
    });
  });

  group('recursion', () {
    List<Map<String, dynamic>> chained() => <Map<String, dynamic>>[
          rawEntry(
            uid: 0,
            keys: <String>['dragon'],
            content: 'The dragon guards the Sunken Chapel.',
          ),
          rawEntry(
              uid: 1, keys: <String>['sunken chapel'], content: 'Chapel lore.'),
        ];

    test('an activated entry can trigger another when the book allows it', () {
      final result = scan(
        sources: <WorldInfoSource>[sourceOf(chained(), recursive: true)],
        history: said('a dragon appears'),
      );
      expect(result.activated, hasLength(2));
    });

    test('recursion stays off when the book does not enable it', () {
      final result = scan(
        sources: <WorldInfoSource>[sourceOf(chained())],
        history: said('a dragon appears'),
      );
      expect(result.activated, hasLength(1));
      expect(result.activated.single.content, contains('dragon guards'));
    });

    test('recursionDepth 0 disables the extra pass', () {
      final result = scan(
        sources: <WorldInfoSource>[sourceOf(chained(), recursive: true)],
        history: said('a dragon appears'),
        recursionDepth: 0,
      );
      expect(result.activated, hasLength(1));
    });

    test('excludeRecursion keeps an entry out of recursive passes', () {
      final entries = <Map<String, dynamic>>[
        rawEntry(
          uid: 0,
          keys: <String>['dragon'],
          content: 'The dragon guards the Sunken Chapel.',
        ),
        rawEntry(
          uid: 1,
          keys: <String>['sunken chapel'],
          content: 'Chapel lore.',
          excludeRecursion: true,
        ),
      ];
      final result = scan(
        sources: <WorldInfoSource>[sourceOf(entries, recursive: true)],
        history: said('a dragon appears'),
      );
      expect(result.activated, hasLength(1));
    });
  });

  group('position bucketing', () {
    test('activated entries are bucketed by their position', () {
      final result = scan(
        sources: <WorldInfoSource>[
          sourceOf(<Map<String, dynamic>>[
            rawEntry(uid: 0, keys: <String>['x'], content: 'a', position: 0),
            rawEntry(uid: 1, keys: <String>['x'], content: 'b', position: 4),
            rawEntry(uid: 2, keys: <String>['x'], content: 'c', position: 4),
          ]),
        ],
        history: said('x'),
      );

      expect(result.at(WorldInfoPosition.beforeChar), hasLength(1));
      expect(result.at(WorldInfoPosition.atDepth), hasLength(2));
      expect(result.at(WorldInfoPosition.afterChar), isEmpty);
    });
  });

  group('timing namespacing', () {
    test('the same uid in two books does not collide', () {
      final timing = WorldInfoTiming();
      final sources = <WorldInfoSource>[
        sourceOf(<Map<String, dynamic>>[
          rawEntry(uid: 0, keys: <String>['x'], sticky: 1),
        ], key: 'character'),
        sourceOf(<Map<String, dynamic>>[
          rawEntry(uid: 0, keys: <String>['x'], sticky: 1),
        ], key: 'global:eldoria'),
      ];

      final result = scan(
        sources: sources,
        history: said('x'),
        timing: timing,
      );

      expect(result.activated, hasLength(2));
      expect(timing['character:0'].stickyLeft, 1);
      expect(timing['global:eldoria:0'].stickyLeft, 1);
    });

    test('timing survives a serialisation round trip', () {
      final timing = WorldInfoTiming();
      timing['a:1'].stickyLeft = 3;
      timing['a:1'].cooldownLeft = 2;
      timing['b:9'].delayLeft = 5;

      final restored = WorldInfoTiming.fromJson(timing.toJson());
      expect(restored['a:1'].stickyLeft, 3);
      expect(restored['a:1'].cooldownLeft, 2);
      expect(restored['b:9'].delayLeft, 5);
    });
  });

  group('debug summary', () {
    test('reports what happened', () {
      final result = scan(
        sources: <WorldInfoSource>[
          sourceOf(<Map<String, dynamic>>[
            rawEntry(uid: 0, keys: <String>['x'], content: 'alpha', order: 1),
            rawEntry(uid: 1, keys: <String>['x'], content: 'beta', order: 2),
          ]),
        ],
        history: said('x'),
        tokenBudget: 1,
        tokenizer: const WordTokenizer(),
      );
      expect(result.debugSummary, contains('activated 1'));
      expect(result.debugSummary, contains('budget-dropped 1'));
    });
  });
}
