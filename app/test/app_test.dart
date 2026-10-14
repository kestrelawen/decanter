import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:decanter/main.dart';
import 'package:decanter/src/chat_controller.dart';
import 'package:decanter/src/chat_content.dart';
import 'package:decanter/src/glass.dart';
import 'package:decanter/src/home_screen.dart';
import 'package:decanter/src/library_platform.dart';
import 'package:decanter/src/library_screen.dart';
import 'package:decanter/src/settings.dart';
import 'package:decanter/src/settings_screen.dart';
import 'package:decanter/src/update_service.dart';
import 'package:decanter_core/decanter_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Card bytes good enough to import, without needing a PNG.
Uint8List cardJsonBytes({
  String name = 'Mira Vance',
  String description = 'A laconic cartographer.',
  String firstMes = 'Hello, traveller.',
}) =>
    utf8.encode(
      jsonEncode(<String, dynamic>{
        'spec': 'chara_card_v2',
        'spec_version': '2.0',
        'data': <String, dynamic>{
          'name': name,
          'description': description,
          'first_mes': firstMes,
        },
      }),
    );

/// An HTTP transport that replays one canned response.
///
/// The field is named `responseBody` rather than `body` on purpose: `send` has a
/// `body` parameter, and having shadowed it once already, this is the version
/// that does not need `this.` to be read correctly.
class StubTransport implements HttpTransport {
  StubTransport({this.statusCode = 200, required this.responseBody});

  final int statusCode;
  final String responseBody;

  Uri? lastUrl;
  Map<String, String>? lastHeaders;
  int calls = 0;

  @override
  Future<StreamedResponse> send({
    required String method,
    required Uri url,
    Map<String, String> headers = const <String, String>{},
    String? body,
  }) async {
    calls++;
    lastUrl = url;
    lastHeaders = headers;
    return StreamedResponse(
      statusCode: statusCode,
      lines: Stream.fromIterable(responseBody.split('\n')),
    );
  }

  @override
  void close() {}
}

/// The bundled card, parsed straight off disk.
///
/// Read with dart:io rather than rootBundle so this asserts the shipped file
/// itself loads — a malformed asset is exactly the failure worth catching before
/// it reaches a device.
TavernCard loadBundledCard() {
  final String raw = File('assets/cards/mira_vance.json').readAsStringSync();
  return TavernCard.fromJson(jsonDecode(raw) as Map<String, dynamic>);
}

const AppSettings configured = AppSettings(
  baseUrl: 'https://api.example.com/v1',
  apiKey: 'sk-test',
  model: 'test-model',
);

/// A backend that replays a fixed reply, or throws.
class ScriptedBackend implements ChatBackend {
  ScriptedBackend(this.deltas, {this.error});

  final List<String> deltas;
  final Object? error;

  ChatRequest? lastRequest;
  bool closed = false;

  @override
  Stream<ChatChunk> stream(ChatRequest request) async* {
    lastRequest = request;
    if (error != null) throw error!;
    for (final String delta in deltas) {
      yield ChatChunk(delta: delta);
    }
    yield const ChatChunk(done: true);
  }

  @override
  Future<void> close() async => closed = true;
}

/// A backend that pushes exactly the chunks a test chooses, when it chooses
/// them — the only way to test cancellation and mid-stream state.
class OpenBackend implements ChatBackend {
  final StreamController<ChatChunk> controller =
      StreamController<ChatChunk>.broadcast();

  bool closed = false;

  @override
  Stream<ChatChunk> stream(ChatRequest request) => controller.stream;

  @override
  Future<void> close() async {
    closed = true;
    if (!controller.isClosed) await controller.close();
  }
}

void main() {
  group('bundled sample card', () {
    test('parses as a V2 card', () {
      final TavernCard card = loadBundledCard();
      expect(card.spec, CardSpec.v2);
      expect(card.name, 'Mira Vance');
      expect(card.greetings, hasLength(2));
    });

    test('carries a lorebook with entries in different prompt slots', () {
      final CharacterBook? book = loadBundledCard().characterBook;
      expect(book, isNotNull);
      expect(book!.entries, hasLength(3));

      final Set<WorldInfoPosition> positions = <WorldInfoPosition>{
        for (final WorldInfoEntry e in book.entries) e.position,
      };
      expect(positions, contains(WorldInfoPosition.beforeChar));
      expect(positions, contains(WorldInfoPosition.afterChar));
      expect(positions, contains(WorldInfoPosition.atDepth));
    });
  });

  group('chat loop', () {
    ChatController controllerWith(
      ChatBackend backend, {
      AppSettings settings = configured,
    }) =>
        ChatController(
          card: loadBundledCard(),
          settings: settings,
          backendFactory: (AppSettings _) => backend,
        );

    test('a streamed reply lands in history', () async {
      final backend = ScriptedBackend(<String>['Hel', 'lo']);
      final controller = controllerWith(backend);

      await controller.send('hi');

      expect(controller.history.last.role, ChatRole.assistant);
      expect(controller.history.last.content, 'Hello');
      expect(controller.error, isNull);
      expect(controller.isStreaming, isFalse);
      expect(backend.closed, isTrue);
      controller.dispose();
    });

    test('the backend receives the assembled prompt', () async {
      final backend = ScriptedBackend(<String>['ok']);
      final controller = controllerWith(backend);

      await controller.send('Tell me about the furnace');

      final ChatRequest request = backend.lastRequest!;
      expect(request.model, 'test-model');
      expect(request.stream, isTrue);
      // The prompt starts with the system area, not the chat.
      expect(request.messages.first.role, ChatRole.system);
      expect(
        request.messages.any((ChatMessage m) => m.content.contains('furnace')),
        isTrue,
      );
      // And the lore that fired reached the assembler.
      expect(controller.scan!.activated, isNotEmpty);
      controller.dispose();
    });

    test('streamingText accumulates while the reply is arriving', () async {
      final backend = OpenBackend();
      final controller = controllerWith(backend);

      final Future<void> turn = controller.send('hi');
      await Future<void>.delayed(Duration.zero);

      backend.controller.add(const ChatChunk(delta: 'She '));
      await Future<void>.delayed(Duration.zero);
      expect(controller.streamingText, 'She ');
      expect(controller.isStreaming, isTrue);

      backend.controller.add(const ChatChunk(delta: 'looks up.'));
      await Future<void>.delayed(Duration.zero);
      expect(controller.streamingText, 'She looks up.');

      backend.controller.add(const ChatChunk(done: true));
      await turn;

      expect(controller.history.last.content, 'She looks up.');
      expect(controller.isStreaming, isFalse);
      controller.dispose();
    });

    test(
      'stop() keeps the partial reply and completes without waiting for '
      'another chunk',
      () async {
        // Regression: with an `await for` loop the turn only ended when the next
        // chunk arrived, so stopping a provider that had gone quiet left the
        // request open and the future pending forever.
        final backend = OpenBackend();
        final controller = controllerWith(backend);

        final Future<void> turn = controller.send('hi');
        await Future<void>.delayed(Duration.zero);
        backend.controller.add(const ChatChunk(delta: 'She starts to answer'));
        await Future<void>.delayed(Duration.zero);

        controller.stop();

        // Must settle immediately, with no further chunks.
        await turn.timeout(const Duration(seconds: 3));

        expect(controller.history.last.content, 'She starts to answer');
        expect(controller.history.last.role, ChatRole.assistant);
        expect(controller.isStreaming, isFalse);
        expect(controller.streamingText, isEmpty);
        controller.dispose();
      },
    );

    test('stop() does not duplicate the partial reply', () async {
      final backend = OpenBackend();
      final controller = controllerWith(backend);

      final Future<void> turn = controller.send('hi');
      await Future<void>.delayed(Duration.zero);
      backend.controller.add(const ChatChunk(delta: 'partial'));
      await Future<void>.delayed(Duration.zero);

      controller.stop();
      await turn;

      final List<ChatMessage> replies = controller.history
          .where((ChatMessage m) => m.content.contains('partial'))
          .toList();
      expect(replies, hasLength(1));
      controller.dispose();
    });

    test('an unconfigured app explains itself instead of failing silently',
        () async {
      final backend = ScriptedBackend(<String>['never sent']);
      final controller = controllerWith(
        backend,
        settings: const AppSettings(apiKey: '', model: '', baseUrl: ''),
      );

      await controller.send('hi');

      expect(controller.error, contains('No backend configured'));
      expect(backend.lastRequest, isNull);
      // The user's message is still recorded, so nothing is lost.
      expect(controller.history.last.role, ChatRole.user);
      controller.dispose();
    });

    test('a rejected key surfaces the friendly message', () async {
      final backend = ScriptedBackend(
        const <String>[],
        error: BackendException(message: 'bad key', statusCode: 401),
      );
      final controller = controllerWith(backend);

      await controller.send('hi');

      expect(controller.error, contains('API key was rejected'));
      expect(controller.isStreaming, isFalse);
      controller.dispose();
    });

    test('an empty reply is reported rather than stored as blank', () async {
      final backend = ScriptedBackend(const <String>[]);
      final controller = controllerWith(backend);

      await controller.send('hi');

      expect(controller.error, contains('empty reply'));
      expect(
        controller.history.where((ChatMessage m) => m.content.trim().isEmpty),
        isEmpty,
      );
      controller.dispose();
    });

    test('removeLastExchange drops the failed turn but keeps the greeting',
        () async {
      final backend = ScriptedBackend(
        const <String>[],
        error: BackendException(message: 'nope', statusCode: 500),
      );
      final controller = controllerWith(backend);

      await controller.send('first attempt');
      expect(controller.history, hasLength(2)); // greeting + user

      controller.removeLastExchange();

      expect(controller.history, hasLength(1));
      expect(controller.history.single.role, ChatRole.assistant);
      expect(controller.error, isNull);
      controller.dispose();
    });

    test('reset() returns to just the greeting', () async {
      final backend = ScriptedBackend(<String>['ok']);
      final controller = controllerWith(backend);
      await controller.send('hi');
      expect(controller.history.length, greaterThan(1));

      controller.reset();

      expect(controller.history, hasLength(1));
      expect(controller.history.single.role, ChatRole.assistant);
      controller.dispose();
    });

    test('useGreeting swaps the opening line', () {
      final controller = controllerWith(ScriptedBackend(const <String>[]));
      final String second = loadBundledCard().greetings[1];

      controller.useGreeting(1);

      expect(controller.history.first.content, second);
      controller.dispose();
    });

    test('navigating swipes alters visible assistant message', () {
      final controller = controllerWith(ScriptedBackend(const <String>[]));
      expect(controller.history.first.swipes.length, 2);
      expect(controller.history.first.swipeIndex, 0);

      controller.nextSwipe(0);
      expect(controller.history.first.swipeIndex, 1);
      expect(controller.history.first.content, loadBundledCard().greetings[1]);

      controller.previousSwipe(0);
      expect(controller.history.first.swipeIndex, 0);
      expect(controller.history.first.content, loadBundledCard().greetings[0]);
      controller.dispose();
    });

    test('regenerate appends a new swipe and updates content', () async {
      final backend = ScriptedBackend(<String>['first reply']);
      final controller = controllerWith(backend);

      await controller.send('Hello');
      expect(controller.history.last.content, 'first reply');
      expect(controller.history.last.swipes, <String>['first reply']);
      expect(controller.history.last.swipeIndex, 0);

      final regenBackend = ScriptedBackend(<String>['second reply']);
      final regenController = ChatController(
        card: loadBundledCard(),
        settings: configured,
        backendFactory: (_) => regenBackend,
      );
      regenController.replaceHistory(controller.history);

      await regenController.regenerate();

      final ChatMessage last = regenController.history.last;
      expect(last.content, 'second reply');
      expect(last.swipes, <String>['first reply', 'second reply']);
      expect(last.swipeIndex, 1);
      expect(last.canSwipeLeft, isTrue);
      expect(last.canSwipeRight, isFalse);

      expect(regenBackend.lastRequest!.messages.last.role, ChatRole.user);
      expect(regenBackend.lastRequest!.messages.last.content, 'Hello');

      regenController.previousSwipe(regenController.history.length - 1);
      expect(regenController.history.last.content, 'first reply');
      expect(regenController.history.last.swipeIndex, 0);

      controller.dispose();
      regenController.dispose();
    });

    test('deleting a swipe removes it and updates active swipe', () {
      final controller = controllerWith(ScriptedBackend(const <String>[]));
      expect(controller.history.first.swipes.length, 2);

      controller.nextSwipe(0);
      expect(controller.history.first.swipeIndex, 1);

      controller.deleteSwipe(0, 1);
      expect(controller.history.first.swipes.length, 1);
      expect(controller.history.first.swipeIndex, 0);
      expect(controller.history.first.content, loadBundledCard().greetings[0]);
      controller.dispose();
    });

    test('editing a message updates active swipe and content', () {
      final controller = controllerWith(ScriptedBackend(const <String>[]));
      expect(controller.history.first.content, loadBundledCard().greetings[0]);

      controller.editMessage(0, 'Custom opening line.');
      expect(controller.history.first.content, 'Custom opening line.');
      expect(controller.history.first.swipes.first, 'Custom opening line.');
      expect(controller.revision, greaterThan(1));
      controller.dispose();
    });

    test('deleting a message removes it from history', () async {
      final backend = ScriptedBackend(<String>['reply']);
      final controller = controllerWith(backend);
      await controller.send('hi');
      expect(controller.history, hasLength(3)); // greeting, user, assistant

      controller.deleteMessage(1); // delete user turn
      expect(controller.history, hasLength(2));
      expect(controller.history.last.role, ChatRole.assistant);
      controller.dispose();
    });

    test('pruneFrom removes from index to the end of history', () async {
      final backend = ScriptedBackend(<String>['reply 1']);
      final controller = controllerWith(backend);
      await controller.send('turn 1');
      expect(controller.history, hasLength(3));

      controller.pruneFrom(1);
      expect(controller.history, hasLength(1));
      expect(controller.history.first.role, ChatRole.assistant);
      controller.dispose();
    });

    test('addNarratorNote inserts a system note into history', () {
      final controller = controllerWith(ScriptedBackend(const <String>[]));
      controller.addNarratorNote('Night falls over the valley.');

      expect(controller.history, hasLength(2));
      expect(controller.history.last.isSystemNote, isTrue);
      expect(controller.history.last.content, 'Night falls over the valley.');
      controller.dispose();
    });

    test('continueGeneration appends reply to previous assistant turn',
        () async {
      final backend = ScriptedBackend(<String>['She stops mid-sentence']);
      final controller = controllerWith(backend);
      await controller.send('tell me');
      expect(controller.history.last.content, 'She stops mid-sentence');

      final continueBackend = ScriptedBackend(<String>[' and continues.']);
      final continueController = ChatController(
        card: loadBundledCard(),
        settings: configured,
        backendFactory: (_) => continueBackend,
      );
      continueController.replaceHistory(controller.history);

      await continueController.continueGeneration();

      expect(continueController.history.last.content,
          'She stops mid-sentence and continues.');
      expect(continueBackend.lastRequest!.messages.last.isSystemNote, isTrue);
      expect(continueBackend.lastRequest!.messages.last.content,
          contains('Continue your previous response'));

      controller.dispose();
      continueController.dispose();
    });
  });

  group('glass system', () {
    testWidgets('a panel renders its child', (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Center(child: GlassPanel(child: Text('glass')))),
        ),
      );
      await tester.pump();
      expect(find.text('glass'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('the sweep overlay leaves its child interactive', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Center(child: SheenSweep(child: Text('sheen')))),
        ),
      );
      await tester.pump(const Duration(milliseconds: 32));
      expect(find.text('sheen'), findsOneWidget);
      expect(find.byType(IgnorePointer), findsWidgets);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  group('home screen', () {
    Future<void> pumpHome(WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: HomeScreen(
            card: loadBundledCard(),
            settings: configured,
            onOpenSettings: () async {},
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }

    testWidgets('shows the character', (WidgetTester tester) async {
      await pumpHome(tester);
      expect(find.text('Mira Vance'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('the lorebook readout is no longer pinned to the screen', (
      WidgetTester tester,
    ) async {
      // Regression for moving it off the bottom: it used to occupy permanent
      // vertical space in the conversation it describes.
      await pumpHome(tester);
      expect(find.text('LOREBOOK'), findsNothing);
      expect(find.text('LAST PROMPT'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('the header button opens the lorebook readout', (
      WidgetTester tester,
    ) async {
      await pumpHome(tester);

      await tester.tap(find.byIcon(Icons.auto_awesome_motion_outlined));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('LOREBOOK'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('sending a message shows it and activates the lore', (
      WidgetTester tester,
    ) async {
      await pumpHome(tester);

      await tester.enterText(
        find.byType(TextField),
        'Tell me about the furnace',
      );
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pump(const Duration(milliseconds: 60));

      expect(find.textContaining('furnace'), findsWidgets);

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('shows swipe counter for greeting with alternates', (
      WidgetTester tester,
    ) async {
      await pumpHome(tester);

      expect(find.text('1/2'), findsOneWidget);
      expect(find.byIcon(Icons.chevron_right_rounded), findsOneWidget);

      await tester.tap(find.byIcon(Icons.chevron_right_rounded));
      await tester.pump();

      expect(find.text('2/2'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('shows CONTINUE button on last assistant message', (
      WidgetTester tester,
    ) async {
      await pumpHome(tester);
      expect(find.text('CONTINUE'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('long press on message bubble opens message actions sheet', (
      WidgetTester tester,
    ) async {
      await pumpHome(tester);
      await tester.longPress(find.byType(ChatRichContent).first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Edit message'), findsOneWidget);
      expect(find.text('Copy text'), findsOneWidget);
      expect(find.text('Delete message'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('tapping more actions button opens message actions sheet', (
      WidgetTester tester,
    ) async {
      await pumpHome(tester);
      await tester.tap(find.byIcon(Icons.more_horiz_rounded));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Edit message'), findsOneWidget);
      expect(find.text('Copy text'), findsOneWidget);
      expect(find.text('Delete message'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  group('update service', () {
    // The channel name is the one part of the update path the analyzer cannot
    // check: a typo on either side — the Dart constant or the Kotlin string —
    // compiles cleanly and fails only on a device, as a MissingPluginException
    // that does not say which side is wrong. Mocking the agreed name here turns
    // that into a failing test.
    const MethodChannel channel = MethodChannel(updateChannelName);

    final List<MethodCall> calls = <MethodCall>[];
    late Directory staging;
    bool allowInstall = true;

    setUp(() {
      TestWidgetsFlutterBinding.ensureInitialized();
      calls.clear();
      allowInstall = true;
      staging = Directory.systemTemp.createTempSync('decanter-update-test');

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
        calls.add(call);
        switch (call.method) {
          case 'canInstallPackages':
            return allowInstall;
          case 'updateDirectory':
            return staging.path;
          case 'install':
            return true;
          case 'openInstallSettings':
            return true;
        }
        return null;
      });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      if (staging.existsSync()) staging.deleteSync(recursive: true);
    });

    test('asks the platform for a staging directory and uses it', () async {
      final UpdateService service = UpdateService();
      addTearDown(service.dispose);

      final Directory directory = await service.updateDirectory();
      expect(directory.path, staging.path);
      expect(calls.single.method, 'updateDirectory');
    });

    test('install hands over the absolute path', () async {
      final UpdateService service = UpdateService();
      addTearDown(service.dispose);

      final File apk = File('${staging.path}/decanter-0.3.0.apk')
        ..writeAsBytesSync(<int>[1, 2, 3]);

      expect(await service.install(apk), isTrue);
      expect(calls.last.method, 'install');
      expect(calls.last.arguments, <String, dynamic>{'path': apk.path});
    });

    test('install does not claim to have started when permission is missing',
        () async {
      allowInstall = false;
      final UpdateService service = UpdateService();
      addTearDown(service.dispose);

      final File apk = File('${staging.path}/decanter-0.3.0.apk')
        ..writeAsBytesSync(<int>[1, 2, 3]);

      // Returning false is the point: the screen must send the user to grant
      // permission rather than report an install that never happened.
      expect(await service.install(apk), isFalse);
      expect(calls.map((MethodCall c) => c.method), <String>[
        'canInstallPackages',
        'openInstallSettings',
      ]);
    });

    test('the installed version parses whether or not CI injected it', () {
      // Outside a --dart-define build this falls back to 0.0.0, which must still
      // be a valid version rather than throwing on the update screen.
      expect(installedVersion.parts, isNotEmpty);
    });
  });

  group('the app shell', () {
    late Directory root;

    setUp(() {
      root = Directory.systemTemp.createTempSync('decanter-shell');
    });

    tearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    testWidgets('the settings button really opens settings', (
      WidgetTester tester,
    ) async {
      // Regression: this did nothing at all when tapped. The handler used
      // Navigator.of(context) with a context belonging to the State that CREATES
      // the MaterialApp, so it sat above the Navigator and threw
      // "does not include a Navigator" — invisible in a release build, which is
      // why the symptom was a dead button rather than a crash.
      await tester.pumpWidget(
        DecanterApp(
          store: LibraryStore(root),
          initialSettings: configured,
          settingsStore: SettingsStore(),
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));

      await tester.tap(find.byIcon(Icons.tune_rounded));
      await tester.pump();
      // Not pumpAndSettle: the drifting background animation never settles.
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('CONNECTION'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('a storage failure is shown rather than swallowed', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        DecanterApp(
          store: LibraryStore(root),
          initialSettings: configured,
          settingsStore: SettingsStore(),
          startupError: 'Could not open a place to save your characters.',
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.textContaining('Could not open a place'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  group('the library', () {
    late Directory root;
    late LibraryStore library;
    const MethodChannel channel = MethodChannel(libraryChannelName);

    /// What the mocked picker returns. Null means the user backed out.
    String? pickResult;

    setUp(() {
      TestWidgetsFlutterBinding.ensureInitialized();
      root = Directory.systemTemp.createTempSync('decanter-library-ui');
      library = LibraryStore(root);
      pickResult = null;

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
        switch (call.method) {
          case 'documentsDirectory':
            return root.path;
          case 'pickCardFile':
            return pickResult;
        }
        return null;
      });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    Future<void> pumpLibrary(WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: LibraryScreen(
            store: library,
            settings: configured,
            onOpenSettings: () async {},
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }

    testWidgets('an empty library explains how to start', (
      WidgetTester tester,
    ) async {
      await pumpLibrary(tester);
      expect(find.textContaining('decanter is empty'), findsOneWidget);
      expect(find.text('IMPORT A CARD'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('lists a stored character with its details', (
      WidgetTester tester,
    ) async {
      library.importCard(
        bytes: cardJsonBytes(name: 'Mira Vance'),
        fileName: 'mira.json',
      );
      await pumpLibrary(tester);

      expect(find.text('Mira Vance'), findsOneWidget);
      expect(find.textContaining('A laconic cartographer'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('a character with a conversation offers CONTINUE', (
      WidgetTester tester,
    ) async {
      final LibraryEntry entry = library.importCard(
        bytes: cardJsonBytes(),
        fileName: 'mira.json',
      );
      library.saveChat(entry.id, <ChatMessage>[
        const ChatMessage(role: ChatRole.user, content: 'hello'),
      ]);

      await pumpLibrary(tester);
      expect(find.text('CONTINUE'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('tapping a character opens its conversation', (
      WidgetTester tester,
    ) async {
      library.importCard(bytes: cardJsonBytes(), fileName: 'mira.json');
      await pumpLibrary(tester);

      await tester.tap(find.text('Mira Vance'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      // The send arrow only exists on the conversation screen.
      expect(find.byIcon(Icons.arrow_upward_rounded), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('importing through the picker adds the character', (
      WidgetTester tester,
    ) async {
      // Exercises the channel name, the platform wrapper, the import and the
      // cache cleanup in one pass — the whole path a user takes.
      final File picked = File('${root.path}/picked.json')
        ..writeAsBytesSync(cardJsonBytes(name: 'Imported Hero'));
      pickResult = picked.path;

      await pumpLibrary(tester);
      await tester.tap(find.text('IMPORT A CARD'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('Imported Hero'), findsOneWidget);
      expect(find.textContaining('Imported'), findsWidgets);
      expect(library.list(), hasLength(1));

      // The picker's copy is a transfer mechanism, not a second home.
      expect(picked.existsSync(), isFalse);

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('backing out of the picker changes nothing', (
      WidgetTester tester,
    ) async {
      pickResult = null;
      await pumpLibrary(tester);

      await tester.tap(find.text('IMPORT A CARD'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      // No error, no phantom entry: cancelling is not a failure.
      expect(library.list(), isEmpty);
      expect(find.textContaining('Could not import'), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('a file that is not a card is refused with a reason', (
      WidgetTester tester,
    ) async {
      final File picked = File('${root.path}/notes.txt')
        ..writeAsStringSync('these are not character cards');
      pickResult = picked.path;

      await pumpLibrary(tester);
      await tester.tap(find.text('IMPORT A CARD'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(library.list(), isEmpty);
      expect(find.textContaining('does not look like a character card'),
          findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('deleting a character asks first, then removes it', (
      WidgetTester tester,
    ) async {
      final LibraryEntry entry = library.importCard(
        bytes: cardJsonBytes(name: 'Doomed'),
        fileName: 'd.json',
      );
      await pumpLibrary(tester);

      await tester.tap(find.byIcon(Icons.delete_outline_rounded));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.textContaining('Delete Doomed?'), findsOneWidget);

      await tester.tap(find.text('Delete'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(library.exists(entry.id), isFalse);

      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  group('conversation persistence', () {
    late Directory root;
    late LibraryStore library;

    setUp(() {
      root = Directory.systemTemp.createTempSync('decanter-persist');
      library = LibraryStore(root);
    });

    tearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    Future<void> pumpChat(WidgetTester tester, String entryId) async {
      await tester.pumpWidget(
        MaterialApp(
          home: HomeScreen(
            card: library.loadCard(entryId),
            settings: configured,
            onOpenSettings: () async {},
            store: library,
            entryId: entryId,
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }

    testWidgets('a stored conversation comes back on the next visit', (
      WidgetTester tester,
    ) async {
      final LibraryEntry entry = library.importCard(
        bytes: cardJsonBytes(),
        fileName: 'mira.json',
      );
      library.saveChat(entry.id, <ChatMessage>[
        const ChatMessage(
          role: ChatRole.assistant,
          content: 'The greeting from last time.',
        ),
        const ChatMessage(role: ChatRole.user, content: 'And my reply.'),
      ]);

      await pumpChat(tester, entry.id);

      expect(find.textContaining('greeting from last time'), findsOneWidget);
      expect(find.textContaining('And my reply'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('a sent message is written to disk', (
      WidgetTester tester,
    ) async {
      final LibraryEntry entry = library.importCard(
        bytes: cardJsonBytes(),
        fileName: 'mira.json',
      );
      await pumpChat(tester, entry.id);

      await tester.enterText(find.byType(TextField), 'Remember this.');
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pump(const Duration(milliseconds: 80));

      // The reply itself cannot arrive here (there is no network in a widget
      // test), but the turn is still on disk, which is what has to survive a
      // process death.
      final StoredChat saved = library.loadChat(entry.id);
      expect(
        saved.messages.map((ChatMessage m) => m.content),
        contains('Remember this.'),
      );

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('new chat clears the stored conversation', (
      WidgetTester tester,
    ) async {
      final LibraryEntry entry = library.importCard(
        bytes: cardJsonBytes(),
        fileName: 'mira.json',
      );
      library.saveChat(entry.id, <ChatMessage>[
        const ChatMessage(role: ChatRole.user, content: 'old turn'),
      ]);
      await pumpChat(tester, entry.id);
      expect(find.textContaining('old turn'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.refresh_rounded));
      await tester.pump(const Duration(milliseconds: 60));

      expect(library.hasChat(entry.id), isFalse);
      expect(find.textContaining('old turn'), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets(
      'opening chats sheet lists threads and allows creating a new chat',
      (WidgetTester tester) async {
        final LibraryEntry entry = library.importCard(
          bytes: cardJsonBytes(),
          fileName: 'mira.json',
        );
        library.saveChat(entry.id, <ChatMessage>[
          const ChatMessage(
            role: ChatRole.assistant,
            content: 'First chat message',
          ),
        ]);
        await pumpChat(tester, entry.id);

        expect(find.byIcon(Icons.forum_outlined), findsOneWidget);
        await tester.tap(find.byIcon(Icons.forum_outlined));
        await tester.pumpAndSettle();

        expect(find.text('CHATS'), findsOneWidget);
        expect(find.text('NEW CHAT'), findsOneWidget);
        expect(find.text('Main Chat'), findsOneWidget);

        await tester.tap(find.text('NEW CHAT'));
        await tester.pumpAndSettle();

        final List<StoredChat> allChats = library.listChats(entry.id);
        expect(allChats.length, 2);

        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    testWidgets(
      'branching from message forks into a new chat thread',
      (WidgetTester tester) async {
        final LibraryEntry entry = library.importCard(
          bytes: cardJsonBytes(),
          fileName: 'mira.json',
        );
        library.saveChat(entry.id, <ChatMessage>[
          const ChatMessage(role: ChatRole.assistant, content: 'Root intro'),
          const ChatMessage(role: ChatRole.user, content: 'Branch point'),
          const ChatMessage(
            role: ChatRole.assistant,
            content: 'Subsequent turn',
          ),
        ]);
        await pumpChat(tester, entry.id);

        expect(find.textContaining('Branch point'), findsOneWidget);

        await tester.tap(find.byIcon(Icons.more_horiz_rounded).first);
        await tester.pumpAndSettle();

        expect(find.text('Branch conversation from here'), findsOneWidget);
        await tester.tap(find.text('Branch conversation from here'));
        await tester.pumpAndSettle();

        final List<StoredChat> chats = library.listChats(entry.id);
        expect(chats.length, 2);

        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    testWidgets('without a library the screen still works, unsaved', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: HomeScreen(
            card: loadBundledCard(),
            settings: configured,
            onOpenSettings: () async {},
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text('Mira Vance'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  group('card pictures', () {
    late Directory root;
    late LibraryStore library;
    late Uint8List picture;

    setUp(() {
      root = Directory.systemTemp.createTempSync('decanter-art');
      library = LibraryStore(root);
      // A real, decodable PNG, standing in for the art sealed inside a PNG card.
      picture = File('assets/background.png').readAsBytesSync();
    });

    tearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    /// A stored card with a picture beside it — the end state a PNG import
    /// leaves behind, without needing a PNG that is also a card.
    LibraryEntry cardWithPicture({String name = 'Light Yagami'}) {
      final LibraryEntry entry = library.importCard(
        bytes: cardJsonBytes(name: name),
        fileName: 'hero.json',
      );
      final Directory directory = Directory(
        '${library.cardsDirectory.path}/${entry.id}',
      );
      File('${directory.path}/source.json').deleteSync();
      File('${directory.path}/source.png').writeAsBytesSync(picture);
      return entry;
    }

    testWidgets('the library shows the picture instead of initials', (
      WidgetTester tester,
    ) async {
      // The reported bug: a card imported with a picture still showed a letter.
      cardWithPicture();

      await tester.pumpWidget(
        MaterialApp(
          home: LibraryScreen(
            store: library,
            settings: configured,
            onOpenSettings: () async {},
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));

      final Iterable<Image> thumbnails = tester
          .widgetList<Image>(find.byType(Image))
          .where((Image image) => image.width == 56);
      expect(thumbnails, isNotEmpty, reason: 'no picture rendered in the row');
      expect(find.text('LY'), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('a card with no picture still falls back to initials', (
      WidgetTester tester,
    ) async {
      library.importCard(
        bytes: cardJsonBytes(name: 'Mira Vance'),
        fileName: 'plain.json',
      );

      await tester.pumpWidget(
        MaterialApp(
          home: LibraryScreen(
            store: library,
            settings: configured,
            onOpenSettings: () async {},
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text('MV'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('the chat is set against the card art', (
      WidgetTester tester,
    ) async {
      final LibraryEntry entry = cardWithPicture();

      await tester.pumpWidget(
        MaterialApp(
          home: HomeScreen(
            card: library.loadCard(entry.id),
            settings: configured,
            onOpenSettings: () async {},
            store: library,
            entryId: entry.id,
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));

      final LiquidBackground background = tester.widget<LiquidBackground>(
        find.byType(LiquidBackground),
      );
      expect(background.image, isA<FileImage>());
      // Character art is busier than the generated backdrop, so it gets a
      // heavier scrim to keep the conversation readable over it.
      expect(background.scrim, greaterThan(1.0));

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('a card with no art keeps the generated backdrop', (
      WidgetTester tester,
    ) async {
      final LibraryEntry entry = library.importCard(
        bytes: cardJsonBytes(),
        fileName: 'plain.json',
      );

      await tester.pumpWidget(
        MaterialApp(
          home: HomeScreen(
            card: library.loadCard(entry.id),
            settings: configured,
            onOpenSettings: () async {},
            store: library,
            entryId: entry.id,
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));

      final LiquidBackground background = tester.widget<LiquidBackground>(
        find.byType(LiquidBackground),
      );
      expect(background.image, isA<AssetImage>());
      expect(background.scrim, 1.0);

      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  group('fetching models', () {
    Future<void> pumpSettings(
      WidgetTester tester,
      StubTransport transport,
    ) async {
      // A tall viewport so the whole settings list is laid out. On the default
      // 800x600 test surface the Model row — and therefore the FETCH button —
      // sits below the fold and is never built, so it cannot be tapped.
      tester.view.physicalSize = const Size(1200, 4800);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          home: SettingsScreen(
            initial: configured.copyWith(
              baseUrl: 'https://api.example.com/v1',
            ),
            transportFactory: () => transport,
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }

    testWidgets('the fetch button lists what the endpoint serves', (
      WidgetTester tester,
    ) async {
      final StubTransport transport = StubTransport(
        responseBody: '{"data":[{"id":"alpha-model"},{"id":"beta-model"}]}',
      );
      await pumpSettings(tester, transport);

      await tester.tap(find.text('FETCH'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(transport.lastUrl!.path, '/v1/models');
      expect(transport.lastHeaders!['Authorization'],
          'Bearer ${configured.apiKey}');
      expect(find.text('alpha-model'), findsOneWidget);
      expect(find.text('beta-model'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('choosing one fills in the model field', (
      WidgetTester tester,
    ) async {
      final StubTransport transport = StubTransport(
        responseBody: '{"data":[{"id":"alpha-model"},{"id":"beta-model"}]}',
      );
      await pumpSettings(tester, transport);

      await tester.tap(find.text('FETCH'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      await tester.tap(find.text('beta-model'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      // The sheet is gone, so the only 'beta-model' left is the field's value.
      expect(find.text('beta-model'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('a rejected key is explained rather than swallowed', (
      WidgetTester tester,
    ) async {
      final StubTransport transport = StubTransport(
        statusCode: 401,
        responseBody: '{"error":{"message":"Invalid API key"}}',
      );
      await pumpSettings(tester, transport);

      await tester.tap(find.text('FETCH'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.textContaining('API key was rejected'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('an endpoint with no /models says so, and suggests typing', (
      WidgetTester tester,
    ) async {
      final StubTransport transport = StubTransport(
        responseBody: '{"nonsense":true}',
      );
      await pumpSettings(tester, transport);

      await tester.tap(find.text('FETCH'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.textContaining('type the name in instead'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  group('chat rich content', () {
    testWidgets('renders plain text with SelectableText', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: ChatRichContent(
              text: 'Hello world',
              isUser: false,
            ),
          ),
        ),
      );
      expect(find.text('Hello world'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('renders asterisks as styled spans and markdown images', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: ChatRichContent(
              text:
                  'Look at this map: ![](www.example.com/map.jpeg) *smiles warmly*',
              isUser: false,
            ),
          ),
        ),
      );
      await tester.pump();

      final Finder imageFinder = find.byType(Image);
      expect(imageFinder, findsOneWidget);
      final Image img = tester.widget<Image>(imageFinder);
      expect(
        (img.image as NetworkImage).url,
        'https://www.example.com/map.jpeg',
      );

      expect(find.textContaining('Look at this map:'), findsOneWidget);
      expect(find.textContaining('smiles warmly'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}
