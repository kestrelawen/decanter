/// Counts tokens for prompt budgeting.
///
/// Budgeting is a first-class concern: a lorebook that overruns the context
/// pushes chat history out of the window, which is the single most common way a
/// roleplay session degrades. Every prompt builder in here takes a [Tokenizer]
/// rather than assuming a counting strategy.
abstract class Tokenizer {
  const Tokenizer();

  /// Estimated tokens in [text].
  int count(String text);

  /// Total across [texts].
  int countAll(Iterable<String> texts) {
    var total = 0;
    for (final t in texts) {
      total += count(t);
    }
    return total;
  }
}

/// A tokenizer-free approximation of a BPE-style count.
///
/// Exact counts are model-specific (each family ships its own merge table), and
/// shipping every vocabulary is not worth the app size. This approximation is
/// deliberately conservative — it rounds up, so budgeting errs toward leaving
/// headroom rather than overfilling the window.
///
/// Swap in a real vocabulary behind [Tokenizer] when a model needs exactness.
class HeuristicTokenizer extends Tokenizer {
  const HeuristicTokenizer();

  /// Average characters per token for English word fragments in BPE tables.
  static const int _charsPerWordToken = 4;

  /// Digits tokenize far less efficiently than letters — a 6-digit number is
  /// typically 2-3 tokens, not 1.
  static const int _charsPerDigitToken = 3;

  @override
  int count(String text) {
    if (text.isEmpty) return 0;

    var tokens = 0;
    // Word runs, digit runs, and lone symbols. Whitespace is free: in BPE it
    // merges into the adjacent token far more often than it becomes its own.
    for (final match in _pattern.allMatches(text)) {
      final piece = match[0]!;
      final first = piece.codeUnitAt(0);

      if (first == 0x20 || first == 0x09 || first == 0x0A || first == 0x0D) {
        continue;
      }
      if (_isDigit(first)) {
        tokens += _ceilDiv(piece.length, _charsPerDigitToken);
      } else if (_isWord(piece)) {
        tokens += _ceilDiv(piece.length, _charsPerWordToken);
      } else {
        // Punctuation and symbols are usually their own token, sometimes merged
        // with a neighbour. One each is the safe reading.
        tokens += piece.length;
      }
    }
    // Whitespace carries no tokens of its own, so whitespace-only input costs
    // nothing rather than a floor of one.
    return tokens;
  }

  static final RegExp _pattern = RegExp(
    r"[A-Za-z']+|[0-9]+|[ \t\r\n]+|[^\sA-Za-z0-9']",
  );

  static bool _isDigit(int c) => c >= 0x30 && c <= 0x39;

  static bool _isWord(String piece) {
    final c = piece.codeUnitAt(0);
    return (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x27;
  }

  static int _ceilDiv(int a, int b) => (a + b - 1) ~/ b;
}

/// A tokenizer that treats each word as one token, for tests that want to
/// reason about budgets in whole units.
class WordTokenizer extends Tokenizer {
  const WordTokenizer();

  @override
  int count(String text) {
    if (text.trim().isEmpty) return 0;
    return text.trim().split(RegExp(r'\s+')).length;
  }
}
