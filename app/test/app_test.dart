import 'dart:convert';
import 'dart:io';

import 'package:decanter/src/glass.dart';
import 'package:decanter/src/home_screen.dart';
import 'package:decanter_core/decanter_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The bundled card, parsed straight off disk.
///
/// Read with dart:io rather than rootBundle so this asserts the shipped file
/// itself is loadable — a malformed asset is exactly the failure worth catching
/// before it reaches a device.
TavernCard loadBundledCard() {
  final String raw = File('assets/cards/mira_vance.json').readAsStringSync();
  return TavernCard.fromJson(jsonDecode(raw) as Map<String, dynamic>);
}

void main() {
  group('bundled sample card', () {
    test('parses as a V2 card', () {
      final TavernCard card = loadBundledCard();
      expect(card.spec, CardSpec.v2);
      expect(card.name, 'Mira Vance');
      expect(card.greetings, hasLength(2));
      expect(card.description, isNotEmpty);
    });

    test('carries a lorebook with entries in different prompt slots', () {
      final CharacterBook? book = loadBundledCard().characterBook;
      expect(book, isNotNull);
      expect(book!.entries, hasLength(3));
      expect(book.active, hasLength(3));

      // The sample is deliberately spread across positions so the in-app
      // inspector shows both a system-block injection and a depth injection.
      final Set<WorldInfoPosition> positions = <WorldInfoPosition>{
        for (final WorldInfoEntry e in book.entries) e.position,
      };
      expect(positions, contains(WorldInfoPosition.beforeChar));
      expect(positions, contains(WorldInfoPosition.afterChar));
      expect(positions, contains(WorldInfoPosition.atDepth));
    });

    test('its lore activates on the right keywords', () {
      final TavernCard card = loadBundledCard();
      final WorldInfoScanResult scan = WorldInfoScanner().scan(
        sources: <WorldInfoSource>[
          WorldInfoSource(key: 'character', book: card.characterBook!),
        ],
        history: <ChatMessage>[
          const ChatMessage(
            role: ChatRole.user,
            content: 'Is the furnace lit tonight?',
          ),
        ],
      );

      expect(scan.activated, isNotEmpty);
      expect(scan.activated.first.keys, contains('furnace'));
    });

    test('nothing activates on unrelated input', () {
      final TavernCard card = loadBundledCard();
      final WorldInfoScanResult scan = WorldInfoScanner().scan(
        sources: <WorldInfoSource>[
          WorldInfoSource(key: 'character', book: card.characterBook!),
        ],
        history: <ChatMessage>[
          const ChatMessage(role: ChatRole.user, content: 'Good morning.'),
        ],
      );
      expect(scan.activated, isEmpty);
    });
  });

  group('glass system', () {
    testWidgets('a panel renders its child', (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(child: GlassPanel(child: Text('glass'))),
          ),
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
          home: Scaffold(
            body: Center(
              child: SheenSweep(child: Text('sheen')),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 32));
      expect(find.text('sheen'), findsOneWidget);
      // The overlay must not swallow taps.
      expect(find.byType(IgnorePointer), findsWidgets);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  group('home screen', () {
    testWidgets('builds and shows the character', (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(home: HomeScreen(card: loadBundledCard())),
      );
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text('Mira Vance'), findsOneWidget);
      expect(find.text('LOREBOOK'), findsOneWidget);

      // Tear the tree down explicitly: the screen owns repeating animations, and
      // leaving an active ticker behind fails the test for the wrong reason.
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('sending a message activates the matching lore', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(home: HomeScreen(card: loadBundledCard())),
      );
      await tester.pump(const Duration(milliseconds: 50));

      await tester.enterText(find.byType(TextField), 'Tell me about the furnace');
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pump(const Duration(milliseconds: 50));

      // The entry's own comment is rendered in the inspector.
      expect(find.text('furnace'), findsWidgets);

      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}
