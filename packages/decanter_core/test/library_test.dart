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

    test('listChats reflects legacy chat file', () {
      final LibraryEntry entry = store.importCard(
        bytes: cardBytes(),
        fileName: 'm.json',
      );
      expect(store.listChats(entry.id), isEmpty);

      store.saveChat(entry.id, <ChatMessage>[
        const ChatMessage(role: ChatRole.assistant, content: 'Legacy hello'),
      ]);

      final List<StoredChat> chats = store.listChats(entry.id);
      expect(chats.length, 1);
      expect(chats.first.id, 'main');
      expect(chats.first.title, 'Main Chat');
      expect(chats.first.messages.single.content, 'Legacy hello');
    });

    test('createNewChat migrates legacy chat and adds new thread', () {
      final LibraryEntry entry = store.importCard(
        bytes: cardBytes(),
        fileName: 'm.json',
      );
      store.saveChat(entry.id, <ChatMessage>[
        const ChatMessage(role: ChatRole.assistant, content: 'Legacy msg'),
      ]);

      final StoredChat newChat = store.createNewChat(
        entry.id,
        title: 'Alternate Timeline',
        initialMessages: <ChatMessage>[
          const ChatMessage(role: ChatRole.assistant, content: 'New greeting'),
        ],
      );

      expect(newChat.title, 'Alternate Timeline');
      expect(newChat.messages.single.content, 'New greeting');

      final List<StoredChat> chats = store.listChats(entry.id);
      expect(chats.length, 2);

      final StoredChat loadedLegacy = store.loadChat(entry.id, 'main');
      expect(loadedLegacy.messages.single.content, 'Legacy msg');

      final StoredChat loadedNew = store.loadChat(entry.id, newChat.id);
      expect(loadedNew.messages.single.content, 'New greeting');
    });

    test('forkChat creates a branch at specific message index', () {
      final LibraryEntry entry = store.importCard(
        bytes: cardBytes(),
        fileName: 'm.json',
      );
      store.saveChat(entry.id, <ChatMessage>[
        const ChatMessage(role: ChatRole.assistant, content: 'Msg 0'),
        const ChatMessage(role: ChatRole.user, content: 'Msg 1'),
        const ChatMessage(role: ChatRole.assistant, content: 'Msg 2'),
        const ChatMessage(role: ChatRole.user, content: 'Msg 3'),
      ]);

      final StoredChat branch = store.forkChat(
        entry.id,
        'main',
        1,
        newTitle: 'Branch from 1',
      );

      expect(branch.title, 'Branch from 1');
      expect(branch.messages.length, 2);
      expect(branch.messages[0].content, 'Msg 0');
      expect(branch.messages[1].content, 'Msg 1');

      // Original chat remains untouched
      final StoredChat mainChat = store.loadChat(entry.id, 'main');
      expect(mainChat.messages.length, 4);
    });

    test('renameChat and deleteChat manage threads individually', () {
      final LibraryEntry entry = store.importCard(
        bytes: cardBytes(),
        fileName: 'm.json',
      );
      final StoredChat chat1 = store.createNewChat(entry.id, title: 'Chat One');
      final StoredChat chat2 = store.createNewChat(entry.id, title: 'Chat Two');

      store.renameChat(entry.id, chat1.id, 'Renamed One');
      expect(store.loadChat(entry.id, chat1.id).title, 'Renamed One');

      store.deleteChat(entry.id, chat2.id);
      final List<StoredChat> remaining = store.listChats(entry.id);
      expect(remaining.map((StoredChat c) => c.id), contains(chat1.id));
      expect(remaining.map((StoredChat c) => c.id), isNot(contains(chat2.id)));
    });

    test('clearChat with chatId deletes only specified thread', () {
      final LibraryEntry entry = store.importCard(
        bytes: cardBytes(),
        fileName: 'm.json',
      );
      final StoredChat chat1 = store.createNewChat(entry.id, title: 'Chat 1');
      final StoredChat chat2 = store.createNewChat(entry.id, title: 'Chat 2');

      store.clearChat(entry.id, chat1.id);
      expect(store.hasChat(entry.id, chat1.id), isFalse);
      expect(store.hasChat(entry.id, chat2.id), isTrue);
      expect(store.hasChat(entry.id), isTrue);

      store.clearChat(entry.id);
      expect(store.hasChat(entry.id), isFalse);
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

  group('card images', () {
    test('a PNG card exposes its picture', () {
      final File file = File(fixtureCard);
      if (!file.existsSync()) {
        markTestSkipped('$fixtureCard not fetched; run tool/fetch_fixtures.sh');
        return;
      }

      final LibraryEntry entry = store.importCard(
        bytes: file.readAsBytesSync(),
        fileName: 'default_Seraphina.png',
      );

      final File? image = store.imageFile(entry.id);
      expect(image, isNotNull);
      expect(image!.path, endsWith('source.png'));
      expect(image.existsSync(), isTrue);
      // Byte-identical to what was imported, so the library shows the picture
      // the user actually handed over rather than a re-render of it.
      expect(image.lengthSync(), file.lengthSync());
    });

    test('a JSON card has no picture, and that is not an error', () {
      final LibraryEntry entry = store.importCard(
        bytes: cardBytes(),
        fileName: 'mira.json',
      );
      expect(store.imageFile(entry.id), isNull);
    });

    test('asking for the picture of an unknown card gives null', () {
      expect(store.imageFile('nobody'), isNull);
    });

    test('the picture and the parsed card live side by side', () {
      final LibraryEntry entry = store.importCard(
        bytes: cardBytes(),
        fileName: 'mira.json',
      );
      // Both survive: the picture is for showing, the JSON is for prompting.
      expect(store.loadCard(entry.id).name, 'Mira Vance');
      expect(store.sourceFile(entry.id)!.existsSync(), isTrue);
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

  group('Card creation, editing, and export', () {
    test('createCard writes card and returns entry', () {
      final TavernCard newCard = TavernCard.create(
        name: 'Lyra',
        description: 'An inventive alchemist.',
        personality: 'Curious, quick-witted.',
        firstMes: 'Welcome to my workshop!',
        alternateGreetings: <String>['Need something brewed?'],
      );

      final LibraryEntry entry = store.createCard(newCard);
      expect(entry.name, 'Lyra');
      expect(entry.greetingCount, 2);
      expect(store.exists(entry.id), isTrue);

      final TavernCard loaded = store.loadCard(entry.id);
      expect(loaded.name, 'Lyra');
      expect(loaded.firstMes, 'Welcome to my workshop!');
      expect(loaded.alternateGreetings, <String>['Need something brewed?']);
    });

    test('saveCard updates existing card content and metadata', () {
      final LibraryEntry initial =
          store.importCard(bytes: cardBytes(name: 'Mira'));
      final TavernCard card = store.loadCard(initial.id);

      final TavernCard updated = card.copyWith(
        name: 'Mira Vance',
        description: 'Updated master cartographer description.',
        personality: 'Quiet and calculating.',
      );

      final LibraryEntry saved = store.saveCard(initial.id, updated);
      expect(saved.name, 'Mira Vance');
      expect(saved.preview, contains('Updated master cartographer'));

      final TavernCard reloaded = store.loadCard(initial.id);
      expect(reloaded.name, 'Mira Vance');
      expect(reloaded.personality, 'Quiet and calculating.');
    });

    test('exportCardJson produces valid Character Card V2 JSON', () {
      final LibraryEntry entry = store.importCard(
        bytes: cardBytes(name: 'Lyra', creator: 'Alchemist'),
      );
      final String jsonStr = store.exportCardJson(entry.id);
      final Map<String, dynamic> decoded =
          jsonDecode(jsonStr) as Map<String, dynamic>;

      expect(decoded['spec'], 'chara_card_v2');
      final Map<String, dynamic> data =
          decoded['data'] as Map<String, dynamic>;
      expect(data['name'], 'Lyra');
      expect(data['creator'], 'Alchemist');
    });

    test('exportChatJson produces SillyTavern-compatible chat export', () {
      final LibraryEntry entry =
          store.importCard(bytes: cardBytes(name: 'Lyra'));
      store.saveChat(
        entry.id,
        <ChatMessage>[
          ChatMessage(
            role: ChatRole.assistant,
            content: 'Greetings traveller.',
          ),
          ChatMessage(role: ChatRole.user, content: 'Hello Lyra!'),
        ],
        chatId: 'thread-1',
        title: 'First Encounter',
      );

      final String jsonStr = store.exportChatJson(
        entry.id,
        'thread-1',
        userName: 'Player1',
      );
      final Map<String, dynamic> decoded =
          jsonDecode(jsonStr) as Map<String, dynamic>;

      expect(decoded['user_name'], 'Player1');
      expect(decoded['character_name'], 'Lyra');
      final List<dynamic> mes = decoded['mes'] as List<dynamic>;
      expect(mes.length, 2);
      expect(mes[0]['name'], 'Lyra');
      expect(mes[0]['mes'], 'Greetings traveller.');
      expect(mes[0]['is_user'], isFalse);
      expect(mes[1]['name'], 'Player1');
      expect(mes[1]['mes'], 'Hello Lyra!');
      expect(mes[1]['is_user'], isTrue);
    });
  });
}

