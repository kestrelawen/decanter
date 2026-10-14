import 'package:decanter_core/decanter_core.dart';
import 'package:test/test.dart';

void main() {
  group('ChatMessage swipes', () {
    test('defaults to no alternate swipes when created with content only', () {
      const message = ChatMessage(role: ChatRole.assistant, content: 'Hello');
      expect(message.swipes, isEmpty);
      expect(message.swipeIndex, 0);
      expect(message.hasSwipes, isFalse);
      expect(message.canSwipeLeft, isFalse);
      expect(message.canSwipeRight, isFalse);
    });

    test('withAddedSwipe creates a list starting with initial content', () {
      const initial = ChatMessage(role: ChatRole.assistant, content: 'First');
      final updated = initial.withAddedSwipe('Second');

      expect(updated.swipes, <String>['First', 'Second']);
      expect(updated.swipeIndex, 1);
      expect(updated.content, 'Second');
      expect(updated.hasSwipes, isTrue);
      expect(updated.canSwipeLeft, isTrue);
      expect(updated.canSwipeRight, isFalse);
    });

    test('withSwipeIndex navigates between alternatives', () {
      final message = const ChatMessage(
        role: ChatRole.assistant,
        content: 'First',
      ).withAddedSwipe('Second').withAddedSwipe('Third');

      expect(message.swipes.length, 3);
      expect(message.swipeIndex, 2);
      expect(message.content, 'Third');

      final atFirst = message.withSwipeIndex(0);
      expect(atFirst.swipeIndex, 0);
      expect(atFirst.content, 'First');
      expect(atFirst.canSwipeLeft, isFalse);
      expect(atFirst.canSwipeRight, isTrue);

      final atSecond = atFirst.withSwipeIndex(1);
      expect(atSecond.swipeIndex, 1);
      expect(atSecond.content, 'Second');
      expect(atSecond.canSwipeLeft, isTrue);
      expect(atSecond.canSwipeRight, isTrue);

      // Out of bounds is ignored
      expect(atSecond.withSwipeIndex(-1), atSecond);
      expect(atSecond.withSwipeIndex(99), atSecond);
    });

    test('withDeletedSwipe removes candidate and clamps active index', () {
      final message = const ChatMessage(
        role: ChatRole.assistant,
        content: 'Alpha',
      ).withAddedSwipe('Beta').withAddedSwipe('Gamma');

      // Delete the currently active swipe (Gamma at index 2)
      final afterDelete = message.withDeletedSwipe(2);
      expect(afterDelete.swipes, <String>['Alpha', 'Beta']);
      expect(afterDelete.swipeIndex, 1);
      expect(afterDelete.content, 'Beta');

      // Delete the first swipe (Alpha at index 0) while Beta at index 1 is active
      final afterDeleteFirst = afterDelete.withDeletedSwipe(0);
      expect(afterDeleteFirst.swipes, <String>['Beta']);
      expect(afterDeleteFirst.swipeIndex, 0);
      expect(afterDeleteFirst.content, 'Beta');
      expect(afterDeleteFirst.hasSwipes, isFalse);

      // Cannot delete the only remaining swipe
      expect(afterDeleteFirst.withDeletedSwipe(0), afterDeleteFirst);
    });

    test('serialisation and deserialisation preserve swipes and swipeIndex',
        () {
      final original = const ChatMessage(
        role: ChatRole.assistant,
        content: 'Option 2',
        swipes: <String>['Option 1', 'Option 2', 'Option 3'],
        swipeIndex: 1,
      );

      final json = original.toJson();
      final roundTrip = ChatMessage.fromJson(json);

      expect(roundTrip.role, ChatRole.assistant);
      expect(roundTrip.content, 'Option 2');
      expect(roundTrip.swipes, <String>['Option 1', 'Option 2', 'Option 3']);
      expect(roundTrip.swipeIndex, 1);
      expect(roundTrip.hasSwipes, isTrue);
    });

    test('deserialisation accepts SillyTavern swipe_id key', () {
      final json = <String, dynamic>{
        'role': 'assistant',
        'content': 'Chosen swipe',
        'swipes': <String>['First swipe', 'Chosen swipe'],
        'swipe_id': 1,
      };

      final parsed = ChatMessage.fromJson(json);
      expect(parsed.swipeIndex, 1);
      expect(parsed.content, 'Chosen swipe');
      expect(parsed.swipes, <String>['First swipe', 'Chosen swipe']);
    });

    test(
        'deserialisation populates swipes from legacy content without swipes key',
        () {
      final json = <String, dynamic>{
        'role': 'user',
        'content': 'Just a message',
      };

      final parsed = ChatMessage.fromJson(json);
      expect(parsed.content, 'Just a message');
      expect(parsed.swipes, <String>['Just a message']);
      expect(parsed.swipeIndex, 0);
      expect(parsed.hasSwipes, isFalse);
    });
  });
}
