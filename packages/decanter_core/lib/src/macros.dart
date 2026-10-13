import 'dart:math' as math;

import 'character_card.dart';

/// The substitution values available while expanding macros.
class MacroContext {
  const MacroContext({
    required this.charName,
    required this.userName,
    this.card,
    this.personaDescription = '',
    this.original,
    this.extra = const <String, String>{},
    this.groupMembers = const <String>[],
  });

  final String charName;
  final String userName;

  /// Source for the card-derived macros. Null in a group chat, where individual
  /// characters have no single card.
  final TavernCard? card;

  final String personaDescription;

  /// The text a `{{original}}` macro should expand to. Used by jailbreak and
  /// main-prompt overrides, which are written as wrappers around the original.
  ///
  /// Inserted textually, so any macros it contains expand on the following
  /// pass rather than being passed through untouched.
  final String? original;

  /// Caller-supplied macros, checked after the built-ins.
  final Map<String, String> extra;

  final List<String> groupMembers;
}

/// Expands `{{macro}}` placeholders in prompt text.
///
/// Unknown macros are left **verbatim** rather than blanked, matching
/// SillyTavern: an unrecognised macro is almost always a typo or a
/// newer-than-us macro, and destroying it silently is worse than showing it.
class MacroExpander {
  MacroExpander({required this.context, math.Random? random})
      : _random = random ?? math.Random();

  final MacroContext context;
  final math.Random _random;

  /// Guards against a macro whose expansion contains another macro looping.
  static const int _maxPasses = 4;

  static final RegExp _macroPattern = RegExp(r'\{\{([^{}]*)\}\}');

  String expand(String input) {
    if (input.isEmpty || !input.contains('{{')) return input;

    var current = input;
    for (var pass = 0; pass < _maxPasses; pass++) {
      final expanded = current.replaceAllMapped(_macroPattern, (match) {
        final resolved = _resolve(match[1]!.trim());
        // Null means "not mine" — keep the literal so it stays visible.
        return resolved ?? match[0]!;
      });
      if (expanded == current) break;
      current = expanded;
    }
    return current;
  }

  /// Expands recursively through a whole collection.
  List<String> expandAll(Iterable<String> inputs) => <String>[
        for (final input in inputs) expand(input),
      ];

  /// Returns the replacement, or null when the macro is not recognised.
  String? _resolve(String token) {
    if (token.isEmpty) return null;

    // A macro may carry an argument: {{roll:1d20}}, {{random:a,b}}.
    final colon = token.indexOf(':');
    final name =
        (colon == -1 ? token : token.substring(0, colon)).toLowerCase().trim();
    final argument = colon == -1 ? '' : token.substring(colon + 1);

    // Caller-provided macros win over built-ins, so an app can override.
    if (context.extra.containsKey(token)) return context.extra[token];
    if (context.extra.containsKey(name)) return context.extra[name];

    final card = context.card;
    switch (name) {
      case 'char':
        return context.charName;
      case 'user':
        return context.userName;
      case 'persona':
        return context.personaDescription;
      case 'description':
        return card?.description ?? '';
      case 'personality':
        return card?.personality ?? '';
      case 'scenario':
        return card?.scenario ?? '';
      case 'mes_example':
      case 'example':
        return card?.mesExample ?? '';
      case 'first_mes':
        return card?.firstMes ?? '';
      case 'creator':
        return card?.creator ?? '';
      case 'charversion':
      case 'char_version':
        return card?.characterVersion ?? '';
      case 'original':
        return context.original ?? '';
      case 'group':
        return context.groupMembers.join(', ');
      case 'newline':
        return '\n';
      case 'random':
      case 'pick':
        return _pick(argument);
      case 'roll':
        return _roll(argument);
      default:
        return null;
    }
  }

  /// `{{random:a,b,c}}` — one of the comma-separated options.
  String _pick(String argument) {
    final options = <String>[
      for (final part in argument.split(','))
        if (part.trim().isNotEmpty) part.trim(),
    ];
    if (options.isEmpty) return '';
    return options[_random.nextInt(options.length)];
  }

  /// `{{roll:1d20}}`, `{{roll:2d6+3}}`, `{{roll:1d20-2}}` — a dice expression.
  ///
  /// Anything that is not a dice expression is passed through unchanged, so a
  /// typo stays visible instead of quietly becoming a number.
  String _roll(String argument) {
    final match = RegExp(
      r'^(\d+)d(\d+)\s*([+-]\s*\d+)?$',
      caseSensitive: false,
    ).firstMatch(argument.trim());
    if (match == null) return '{{roll:$argument}}';

    final dice = int.tryParse(match[1]!) ?? 0;
    final sides = int.tryParse(match[2]!) ?? 0;
    if (dice <= 0 || sides <= 0 || dice > 100 || sides > 1000) {
      return '{{roll:$argument}}';
    }

    var total = 0;
    for (var i = 0; i < dice; i++) {
      total += 1 + _random.nextInt(sides);
    }

    final modifier = match[3];
    if (modifier != null) {
      total += int.tryParse(modifier.replaceAll(RegExp(r'\s+'), '')) ?? 0;
    }
    return '$total';
  }
}
