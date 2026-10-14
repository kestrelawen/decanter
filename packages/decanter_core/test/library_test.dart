import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:decanter_core/decanter_core.dart';
import 'package:test/test.dart';

/// A real SillyTavern PNG card, fetched by `tool/fetch_fixtures.sh` and
/// gitignored (it is AGPL-3.0 content owned by the SillyTavern project). Tests
/// that need it skip when it is absent.
const String fixtureCard = 'testdata/real/default_Seraphina.png';

Uint8List cardBytes({
  String name = 'Mira Vance',
  String creator = 'Tester',
  String description = 'A laconic cartographer.',
  List<String> greetings = const <String>['Hello.'],
  Map<String, dynamic>? extra,
}) =>
    Uint8List.fromList(
      utf8.encode(
        jsonEncode(<String, dynamic>{
          'spec': 'chara_card_v2',
          'spec_version': '2.0',
          'data': <String, dynamic>{
            'name': name,
            'description': description,
            'creator': creator,
            'first_mes': greetings.isEmpty ? '' : greetings.first,
            'alternate_greetings': greetings.skip(1).toList(),
            ...?extra,
          },
        }),
      ),
    );

void main() {
  late Directory root;
  late LibraryStore store;

  setUp(() {
    root = Directory.systemTemp.createTempSync('decanter-library');
    store = LibraryStore(root);
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  group('slugify', () {
    test('lowercases and separates words with dashes', () {
      expect(slugify('Mira Vance'), 'mira-vance');
    });

    test('drops punctuation instead of escaping it', () {
      expect(slugify("O'Brien & Sons!"), 'o-brien-sons');
    });

    test('collapses runs of separators', () {
      expect(slugify('a   ---   b'), 'a-b');
    });

    test('trims leading and trailing separators', () {
      expect(slugify('  --Hi--  '), 'hi');
    });

    test('keeps digits', () {
      expect(slugify('R2-D2'), 'r2-d2');
    });

    test('a name with nothing usable gives an empty slug', () {
      expect(slugify(''), '');
      expect(slugify('!!!'), '');
      expect(slugify('日本語'), '');
    });

    test('caps the length so a name cannot become a path problem', () {
      expect(slugify('x' * 200).length, 48);
    });
  });

  group('decodeCardBytes', () {
    test('reads bare JSON', () {
      expect(decodeCardBytes(cardBytes()).name, 'Mira Vance');
    });

    test('names the file in the error when it is neither PNG nor JSON', () {
      expect(
        () => decodeCardBytes(
          Uint8List.fromList(utf8.encode('<html>nope</html>')),
          fileName: 'card.html',
        ),
        throwsA(
          predicate(
            (Object e) =>
                e is CardFormatException && e.message.contains('card.html'),
          ),
        ),
      );
    });

    test('recognises a .charx archive and says so', () {
      expect(
        () => decodeCardBytes(
          Uint8List.fromList(<int>[0x50, 0x4B, 0x03, 0x04, 0, 0, 0, 0]),
          fileName: 'hero.charx',
        ),
        throwsA(
          predicate(
            (Object e) =>
                e is CardFormatException && e.message.contains('charx'),
          ),
        ),
      );
    });
  });

  group('import', () {
    test('stores a card and lists it', () {
      final LibraryEntry entry = store.importCard(
        bytes: cardBytes(),
        fileName: 'mira.json',
      );

      expect(entry.id, 'mira-vance');
      expect(entry.name, 'Mira Vance');
      expect(entry.creator, 'Tester');
      expect(entry.spec, 'chara_card_v2');
      expect(entry.greetingCount, 1);
      expect(entry.importedAt, isNotNull);
      expect(entry.preview, 'A laconic cartographer.');

      expect(store.list(), hasLength(1));
      expect(store.exists(entry.id), isTrue);
      expect(store.loadCard(entry.id).name, 'Mira Vance');
    });

    test('keeps the original bytes alongside the parsed card', () {
      final Uint8List bytes = cardBytes();
      final LibraryEntry entry = store.importCard(
        bytes: bytes,
        fileName: 'mira.json',
      );

      final File? source = store.sourceFile(entry.id);
      expect(source, isNotNull);
      expect(source!.path, endsWith('source.json'));
      expect(source.lengthSync(), bytes.length);
    });

    test('preserves keys the model does not understand', () {
      final LibraryEntry entry = store.importCard(
        bytes: cardBytes(
          extra: <String, dynamic>{
            'group_only_greetings': <String>['hi'],
            'x_custom': 42,
          },
        ),
        fileName: 'x.json',
      );

      final Map<String, dynamic> data =
          store.loadCard(entry.id).toJson()['data'] as Map<String, dynamic>;
      expect(data['group_only_greetings'], <String>['hi']);
      expect(data['x_custom'], 42);
    });

    test('counts lorebook entries', () {
      final LibraryEntry entry = store.importCard(
        bytes: cardBytes(
          extra: <String, dynamic>{
            'character_book': <String, dynamic>{
              'name': 'Eldoria',
              'entries': <Map<String, dynamic>>[
                <String, dynamic>{
                  'uid': 0,
                  'keys': <String>['furnace'],
                  'content': 'The furnace burns.',
                  'enabled': true,
                },
                <String, dynamic>{
                  'uid': 1,
                  'keys': <String>['ash'],
                  'content': 'Ash falls.',
                  'enabled': true,
                },
              ],
            },
          },
        ),
        fileName: 'lore.json',
      );

      expect(entry.loreCount, 2);
    });

    test('counts alternate greetings', () {
      final LibraryEntry entry = store.importCard(
        bytes: cardBytes(greetings: <String>['One.', 'Two.', 'Three.']),
        fileName: 'g.json',
      );
      expect(entry.greetingCount, 3);
      expect(entry.hasAlternateGreetings, isTrue);
    });

    test('a second card with the same name gets its own directory', () {
      final LibraryEntry first = store.importCard(
        bytes: cardBytes(),
        fileName: 'a.json',
      );
      final LibraryEntry second = store.importCard(
        bytes: cardBytes(),
        fileName: 'b.json',
      );

      expect(first.id, 'mira-vance');
      expect(second.id, 'mira-vance-2');
      expect(store.list(), hasLength(2));
      // And they are genuinely separate documents.
      expect(store.loadCard(first.id).name, 'Mira Vance');
      expect(store.loadCard(second.id).name, 'Mira Vance');
    });

    test('an unnamed card falls back to the file name', () {
      final LibraryEntry entry = store.importCard(
        bytes: cardBytes(name: '   '),
        fileName: 'shadowy-figure.png',
      );
      expect(entry.id, 'shadowy-figure');
    });

    test('rejects junk and writes nothing at all', () {
      expect(
        () => store.importCard(
          bytes: Uint8List.fromList(utf8.encode('<html>nope</html>')),
          fileName: 'x.html',
        ),
        throwsA(isA<CardFormatException>()),
      );

      expect(store.list(), isEmpty);
      expect(store.cardsDirectory.listSync(), isEmpty);
    });

    test('imports a real PNG card, and keeps its image', () {
      final File file = File(fixtureCard);
      if (!file.existsSync()) {
        markTestSkipped('$fixtureCard not fetched; run tool/fetch_fixtures.sh');
        return;
      }

      final Uint8List bytes = file.readAsBytesSync();
      final LibraryEntry entry = store.importCard(
        bytes: bytes,
        fileName: 'default_Seraphina.png',
      );

      expect(entry.name, isNotEmpty);
      expect(entry.id, isNotEmpty);
      expect(entry.spec, contains('chara_card'));
      expect(entry.greetingCount, greaterThanOrEqualTo(1));
      expect(store.loadCard(entry.id).name, entry.name);

      // The image is recoverable, byte for byte.
      final File? source = store.sourceFile(entry.id);
      expect(source!.path, endsWith('source.png'));
      expect(source.lengthSync(), bytes.length);
    });
  });

  group('listing', () {
    test('an empty root is created rather than failing', () {
      final LibraryStore fresh = LibraryStore(
        Directory('${root.path}/not-yet-created'),
      );
      expect(fresh.list(), isEmpty);
      expect(fresh.cardsDirectory.existsSync(), isTrue);
      expect(fresh.chatsDirectory.existsSync(), isTrue);
    });

    test('sorts by import time, newest first', () {
      final LibraryEntry older = store.importCard(
        bytes: cardBytes(name: 'Older'),
        fileName: 'o.json',
      );
      final LibraryEntry newer = store.importCard(
        bytes: cardBytes(name: 'Newer'),
        fileName: 'n.json',
      );

      // Backdate the first so this is not a same-millisecond tie.
      final File meta = File(
        '${store.cardsDirectory.path}/${older.id}/meta.json',
      );
      final Map<String, dynamic> decoded =
          jsonDecode(meta.readAsStringSync()) as Map<String, dynamic>;
      decoded['importedAt'] =
          DateTime.now().subtract(const Duration(days: 2)).toIso8601String();
      meta.writeAsStringSync(jsonEncode(decoded));

      expect(store.list().map((LibraryEntry e) => e.id).toList(), <String>[
        newer.id,
        older.id,
      ]);
    });

    test('one corrupt card does not hide the rest of the library', () {
      final LibraryEntry good = store.importCard(
        bytes: cardBytes(name: 'Good'),
        fileName: 'g.json',
      );
      final LibraryEntry broken = store.importCard(
        bytes: cardBytes(name: 'Broken'),
        fileName: 'b.json',
      );

      File(
        '${store.cardsDirectory.path}/${broken.id}/meta.json',
      ).writeAsStringSync('{ not json at all');

      final List<LibraryEntry> listed = store.list();
      expect(listed.map((LibraryEntry e) => e.id), contains(good.id));
      expect(listed.map((LibraryEntry e) => e.id), isNot(contains(broken.id)));
    });

    test('a stray directory is ignored', () {
      Directory(
        '${store.cardsDirectory.path}/stray',
      ).createSync(recursive: true);
      expect(store.list(), isEmpty);
    });

    test('find locates a card, and misses cleanly', () {
      final LibraryEntry entry = store.importCard(
        bytes: cardBytes(),
        fileName: 'm.json',
      );
      expect(store.find(entry.id)?.name, 'Mira Vance');
      expect(store.find('nobody'), isNull);
    });

    test('loading a card that is not there explains the id', () {
      expect(
        () => store.loadCard('nobody'),
        throwsA(
          predicate(
            (Object e) =>
                e is CardFormatException && e.message.contains('nobody'),
          ),
        ),
      );
    });
  });

  group('chats', () {
    test('save then load round-trips the conversation', () {
      final LibraryEntry entry = store.importCard(
        bytes: cardBytes(),
        fileName: 'm.json',
      );

      store.saveChat(entry.id, <ChatMessage>[
        const ChatMessage(role: ChatRole.assistant, content: 'Hello.'),
        const ChatMessage(role: ChatRole.user, content: 'Hi.'),
      ]);

      expect(store.hasChat(entry.id), isTrue);
      final StoredChat chat = store.loadChat(entry.id);
      expect(chat.messageCount, 2);
      expect(chat.messages.first.role, ChatRole.assistant);
      expect(chat.messages.last.content, 'Hi.');
      expect(chat.savedAt, isNotNull);
    });

    test('a chat that was never saved is empty, not an error', () {
      expect(store.loadChat('nobody').isEmpty, isTrue);
      expect(store.hasChat('nobody'), isFalse);
    });

    test('a corrupt chat degrades to empty rather than failing a launch', () {
      final LibraryEntry entry = store.importCard(
        bytes: cardBytes(),
        fileName: 'm.json',
      );
      File(
        '${store.chatsDirectory.path}/${entry.id}.json',
      ).writeAsStringSync('[[[');

      expect(store.loadChat(entry.id).isEmpty, isTrue);
    });

    test('saving leaves no temporary file behind', () {
      final LibraryEntry entry = store.importCard(
        bytes: cardBytes(),
        fileName: 'm.json',
      );
      store.saveChat(entry.id, <ChatMessage>[
        const ChatMessage(role: ChatRole.user, content: 'x'),
      ]);

      expect(
        File('${store.chatsDirectory.path}/${entry.id}.json.tmp').existsSync(),
        isFalse,
      );
      expect(
        store.chatsDirectory
            .listSync()
            .whereType<File>()
            .map((File f) => f.path.split(Platform.pathSeparator).last)
            .toList(),
        <String>['${entry.id}.json'],
      );
    });

    test('saving twice replaces rather than appends', () {
      final LibraryEntry entry = store.importCard(
        bytes: cardBytes(),
        fileName: 'm.json',
      );
      store.saveChat(entry.id, <ChatMessage>[
        const ChatMessage(role: ChatRole.user, content: 'first'),
      ]);
      store.saveChat(entry.id, <ChatMessage>[
        const ChatMessage(role: ChatRole.user, content: 'second'),
      ]);

      final StoredChat chat = store.loadChat(entry.id);
      expect(chat.messageCount, 1);
      expect(chat.messages.single.content, 'second');
    });

    test('clearChat removes the conversation but keeps the card', () {
      final LibraryEntry entry = store.importCard(
        bytes: cardBytes(),
        fileName: 'm.json',
      );
      store.saveChat(entry.id, <ChatMessage>[
        const ChatMessage(role: ChatRole.user, content: 'x'),
      ]);

      store.clearChat(entry.id);
      expect(store.hasChat(entry.id), isFalse);
      expect(store.exists(entry.id), isTrue);
    });

    test('clearing a chat that does not exist is a no-op', () {
      expect(() => store.clearChat('nobody'), returnsNormally);
    });
  });

  group('delete', () {
    test('removes the card and its conversation together', () {
      final LibraryEntry entry = store.importCard(
        bytes: cardBytes(),
        fileName: 'm.json',
      );
      store.saveChat(entry.id, <ChatMessage>[
        const ChatMessage(role: ChatRole.user, content: 'x'),
      ]);

      store.delete(entry.id);

      expect(store.list(), isEmpty);
      expect(store.exists(entry.id), isFalse);
      expect(store.hasChat(entry.id), isFalse);
    });

    test('deleting something absent is a no-op', () {
      expect(() => store.delete('nobody'), returnsNormally);
    });
  });

  group('entry serialisation', () {
    test('round-trips through JSON', () {
      final LibraryEntry entry = LibraryEntry(
        id: 'mira',
        name: 'Mira',
        creator: 'Someone',
        fileName: 'mira.png',
        preview: 'A cartographer.',
        greetingCount: 3,
        loreCount: 4,
        spec: 'chara_card_v3',
        importedAt: DateTime.utc(2026, 10, 13, 12),
      );
      final LibraryEntry restored = LibraryEntry.fromJson(
        jsonDecode(jsonEncode(entry.toJson())) as Map<String, dynamic>,
      );

      expect(restored.id, entry.id);
      expect(restored.name, entry.name);
      expect(restored.greetingCount, 3);
      expect(restored.loreCount, 4);
      expect(restored.spec, 'chara_card_v3');
      expect(restored.importedAt, entry.importedAt);
    });

    test('a sparse document yields usable defaults', () {
      final LibraryEntry entry = LibraryEntry.fromJson(<String, dynamic>{});
      expect(entry.name, 'Unnamed');
      expect(entry.greetingCount, 1);
      expect(entry.loreCount, 0);
      expect(entry.importedAt, isNull);
    });
  });
}
