import 'package:decanter_core/decanter_core.dart';
import 'package:test/test.dart';

void main() {
  group('HeuristicTokenizer', () {
    const tokenizer = HeuristicTokenizer();

    test('empty input costs nothing', () {
      expect(tokenizer.count(''), 0);
    });

    test('whitespace alone costs nothing', () {
      expect(tokenizer.count('   \n\t '), 0);
    });

    test('a word costs at least one token', () {
      expect(tokenizer.count('hi'), greaterThanOrEqualTo(1));
    });

    test('counts grow with length', () {
      final short = tokenizer.count('hello world');
      final long = tokenizer.count(
        'hello world this is a considerably longer sentence with many words',
      );
      expect(long, greaterThan(short));
    });

    test('is roughly four characters per token for prose', () {
      final text = 'the quick brown fox jumps over the lazy dog';
      final estimate = tokenizer.count(text);
      // Loose sanity band: real BPE would land near len/4.
      expect(estimate, inInclusiveRange(6, 20));
    });

    test('digits cost more than letters of the same length', () {
      expect(tokenizer.count('123456'),
          greaterThanOrEqualTo(tokenizer.count('abcdef')));
    });

    test('any non-empty text costs at least one token', () {
      expect(tokenizer.count('.'), greaterThanOrEqualTo(1));
      expect(tokenizer.count('!'), greaterThanOrEqualTo(1));
    });
  });

  group('WordTokenizer', () {
    const tokenizer = WordTokenizer();

    test('counts whitespace-separated words', () {
      expect(tokenizer.count('one two three'), 3);
    });

    test('collapses repeated whitespace', () {
      expect(tokenizer.count('one   two\n\nthree'), 3);
    });

    test('empty and whitespace-only input is zero', () {
      expect(tokenizer.count(''), 0);
      expect(tokenizer.count('   '), 0);
    });
  });

  group('countAll', () {
    test('sums across a collection', () {
      const tokenizer = WordTokenizer();
      expect(tokenizer.countAll(<String>['a b', 'c', 'd e f']), 6);
    });

    test('an empty collection is zero', () {
      const tokenizer = WordTokenizer();
      expect(tokenizer.countAll(const <String>[]), 0);
    });
  });
}
