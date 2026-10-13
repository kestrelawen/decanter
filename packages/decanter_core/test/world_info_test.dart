import 'package:decanter_core/decanter_core.dart';
import 'package:test/test.dart';

void main() {
  group('entry parsing', () {
    test('reads the native field spellings', () {
      final book = CharacterBook.fromNativeJson(<String, dynamic>{
        'entries': <String, dynamic>{
          '0': <String, dynamic>{
            'uid': 0,
            'key': <String>['Sunken Chapel', 'chapel'],
            'keysecondary': <String>['Mara'],
            'content': 'A flooded chapel beneath the reservoir.',
            'comment': 'chapel lore',
            'constant': false,
            'selective': true,
            'selectiveLogic': 0,
            'order': 50,
            'position': 4,
            'depth': 3,
            'probability': 100,
            'useProbability': true,
            'scanDepth': 4,
            'disable': false,
            'role': 'system',
          },
        },
      });

      expect(book.entries, hasLength(1));
      final e = book.entries.single;
      expect(e.uid, 0);
      expect(e.keys, <String>['Sunken Chapel', 'chapel']);
      expect(e.secondaryKeys, <String>['Mara']);
      expect(e.content, 'A flooded chapel beneath the reservoir.');
      expect(e.comment, 'chapel lore');
      expect(e.selective, isTrue);
      expect(e.insertionOrder, 50);
      expect(e.position, WorldInfoPosition.atDepth);
      expect(e.depth, 3);
      expect(e.scanDepth, 4);
      expect(e.role, 'system');
      expect(e.contributes, isTrue);
    });

    test('native `disable: true` inverts to enabled == false', () {
      final book = CharacterBook.fromNativeJson(<String, dynamic>{
        'entries': <String, dynamic>{
          '7': <String, dynamic>{
            'uid': 7,
            'key': <String>['x'],
            'content': 'c',
            'disable': true
          },
        },
      });
      expect(book.entries.single.enabled, isFalse);
      expect(book.entries.single.contributes, isFalse);
      expect(book.active, isEmpty);
    });

    test('the V2 array layout loads too', () {
      final book = CharacterBook.fromJson(<String, dynamic>{
        'name': 'Embedded',
        'entries': <dynamic>[
          <String, dynamic>{
            'keys': <String>['a'],
            'content': 'first',
            'enabled': true,
            'insertion_order': 10,
          },
          <String, dynamic>{
            'keys': <String>['b'],
            'content': 'second',
            'enabled': false,
            'insertion_order': 20,
          },
        ],
      });

      expect(book.entries, hasLength(2));
      expect(book.entries[0].keys, <String>['a']);
      expect(book.entries[0].insertionOrder, 10);
      expect(book.entries[0].enabled, isTrue);
      expect(book.entries[0].content, 'first');
      expect(book.entries[1].enabled, isFalse);
      // Array entries get their index as uid, since V2 has no uid field.
      expect(book.entries[1].uid, 1);
      expect(book.active, hasLength(1));
    });

    test('an entry with empty content never contributes', () {
      final book = CharacterBook.fromJson(<String, dynamic>{
        'entries': <dynamic>[
          <String, dynamic>{
            'keys': <String>['a'],
            'content': '   ',
            'enabled': true
          },
        ],
      });
      expect(book.entries.single.enabled, isTrue);
      expect(book.entries.single.contributes, isFalse);
      expect(book.active, isEmpty);
    });

    test('outlet and group metadata are read', () {
      final book = CharacterBook.fromNativeJson(<String, dynamic>{
        'entries': <String, dynamic>{
          'a': <String, dynamic>{
            'uid': 12,
            'key': <String>['k'],
            'content': 'c',
            'position': 7,
            'outletName': 'Weather',
            'group': 'weather',
            'groupWeight': 30,
            'sticky': 3,
            'cooldown': 5,
            'delay': 2,
          },
        },
      });
      final e = book.entries.single;
      // The key is "a" but uid is 12 — SillyTavern would not render this entry,
      // so the uid from the body must win.
      expect(e.uid, 12);
      expect(e.position, WorldInfoPosition.outlet);
      expect(e.outletName, 'Weather');
      expect(e.group, 'weather');
      expect(e.groupWeight, 30);
      expect(e.sticky, 3);
      expect(e.cooldown, 5);
      expect(e.delay, 2);
    });
  });

  group('position enum', () {
    test('maps every documented wire value', () {
      const expected = <int, WorldInfoPosition>{
        0: WorldInfoPosition.beforeChar,
        1: WorldInfoPosition.afterChar,
        2: WorldInfoPosition.anTop,
        3: WorldInfoPosition.anBottom,
        4: WorldInfoPosition.atDepth,
        5: WorldInfoPosition.emTop,
        6: WorldInfoPosition.emBottom,
        7: WorldInfoPosition.outlet,
      };
      expected.forEach((wire, position) {
        expect(WorldInfoPosition.fromWire(wire), position);
        expect(position.wire, wire);
      });
    });

    test('accepts a numeric string and defaults unknown values', () {
      expect(WorldInfoPosition.fromWire('5'), WorldInfoPosition.emTop);
      expect(WorldInfoPosition.fromWire(99), WorldInfoPosition.beforeChar);
      expect(WorldInfoPosition.fromWire(null), WorldInfoPosition.beforeChar);
    });
  });

  group('selective logic', () {
    test('maps the four documented modes', () {
      expect(SelectiveLogic.fromWire(0), SelectiveLogic.andAny);
      expect(SelectiveLogic.fromWire(1), SelectiveLogic.notAll);
      expect(SelectiveLogic.fromWire(2), SelectiveLogic.notAny);
      expect(SelectiveLogic.fromWire(3), SelectiveLogic.andAll);
    });
  });

  group('round-trip', () {
    test('disable is written back inverted and unknown keys survive', () {
      final source = <String, dynamic>{
        'entries': <String, dynamic>{
          '3': <String, dynamic>{
            'uid': 3,
            'key': <String>['k'],
            'content': 'c',
            'disable': true,
            'vectorized': false,
            'automationId': 'custom-id',
            'displayIndex': 4,
          },
        },
      };

      final out = CharacterBook.fromNativeJson(source).toJson();
      final entries = out['entries'] as List<dynamic>;
      final first = entries.single as Map<String, dynamic>;

      expect(first['disable'], isTrue);
      expect(first['uid'], 3);
      expect(first['key'], <String>['k']);
      // Fields this version does not model are preserved.
      expect(first['automationId'], 'custom-id');
      expect(first['displayIndex'], 4);
      expect(first['vectorized'], isFalse);
    });

    test('enabled entries write disable: false', () {
      final out = CharacterBook.fromJson(<String, dynamic>{
        'entries': <dynamic>[
          <String, dynamic>{
            'keys': <String>['a'],
            'content': 'c',
            'enabled': true
          },
        ],
      }).toJson();
      final first =
          (out['entries'] as List<dynamic>).single as Map<String, dynamic>;
      expect(first['disable'], isFalse);
    });
  });

  group('validation', () {
    test('a file with no entries key is not a world-info file', () {
      expect(
        () => CharacterBook.fromNativeJson(<String, dynamic>{'foo': 'bar'}),
        throwsA(isA<FormatException>()),
      );
    });

    test('book-level metadata is read', () {
      final book = CharacterBook.fromJson(<String, dynamic>{
        'name': 'World',
        'description': 'desc',
        'scan_depth': 4,
        'token_budget': 512,
        'recursive_scanning': true,
        'extensions': <String, dynamic>{},
        'entries': <dynamic>[],
      });
      expect(book.name, 'World');
      expect(book.scanDepth, 4);
      expect(book.tokenBudget, 512);
      expect(book.recursiveScanning, isTrue);
    });
  });
}
