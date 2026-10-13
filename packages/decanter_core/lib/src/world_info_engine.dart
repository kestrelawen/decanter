import 'dart:math' as math;

import 'chat.dart';
import 'tokenizer.dart';
import 'world_info.dart';

/// A lorebook together with the key its timing state is namespaced under.
///
/// Entry uids are only unique *within* a book, so a global book and a
/// character book can both hold a uid 3 meaning different entries. Timing state
/// is therefore keyed by `"<sourceKey>:<uid>"`, never by uid alone.
class WorldInfoSource {
  const WorldInfoSource({required this.key, required this.book});

  /// Stable identifier for this book, e.g. `character` or `global:eldoria`.
  final String key;

  final CharacterBook book;

  @override
  String toString() => 'WorldInfoSource($key, ${book.entries.length} entries)';
}

/// Per-entry counters that advance one message at a time.
class EntryTiming {
  EntryTiming({this.stickyLeft = 0, this.cooldownLeft = 0, this.delayLeft = 0});

  /// Messages this entry stays active for, even without a key match.
  int stickyLeft;

  /// Messages before this entry may activate again.
  int cooldownLeft;

  /// Messages before this entry becomes eligible at all.
  int delayLeft;

  bool get isSticky => stickyLeft > 0;
  bool get isCoolingDown => cooldownLeft > 0;
  bool get isDelayed => delayLeft > 0;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'stickyLeft': stickyLeft,
        'cooldownLeft': cooldownLeft,
        'delayLeft': delayLeft,
      };

  factory EntryTiming.fromJson(Map<String, dynamic> json) => EntryTiming(
        stickyLeft: _int(json['stickyLeft']),
        cooldownLeft: _int(json['cooldownLeft']),
        delayLeft: _int(json['delayLeft']),
      );

  static int _int(Object? v) => v is int ? v : int.tryParse('$v') ?? 0;
}

/// The whole chat's lorebook timing state. Persist it with the chat, or stale
/// cooldowns leak between sessions.
class WorldInfoTiming {
  /// Explicit, because declaring the [WorldInfoTiming.fromJson] factory
  /// suppresses the implicit default constructor.
  WorldInfoTiming();

  final Map<String, EntryTiming> _byKey = <String, EntryTiming>{};

  EntryTiming operator [](String key) =>
      _byKey.putIfAbsent(key, EntryTiming.new);

  bool hasStateFor(String key) => _byKey.containsKey(key);

  Map<String, EntryTiming> get entries =>
      Map<String, EntryTiming>.unmodifiable(_byKey);

  /// Advances every counter by one message.
  void advanceOneMessage() {
    for (final timing in _byKey.values) {
      if (timing.stickyLeft > 0) timing.stickyLeft--;
      if (timing.cooldownLeft > 0) timing.cooldownLeft--;
      if (timing.delayLeft > 0) timing.delayLeft--;
    }
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        for (final e in _byKey.entries) e.key: e.value.toJson(),
      };

  factory WorldInfoTiming.fromJson(Map<String, dynamic> json) {
    final timing = WorldInfoTiming();
    json.forEach((key, value) {
      if (value is Map) {
        timing._byKey[key] = EntryTiming.fromJson(
          Map<String, dynamic>.from(value),
        );
      }
    });
    return timing;
  }
}

/// What a scan decided.
class WorldInfoScanResult {
  const WorldInfoScanResult({
    required this.activated,
    required this.byPosition,
    required this.excludedByBudget,
    required this.droppedByGroup,
    required this.tokenCost,
    required this.timing,
  });

  /// Entries that will actually be injected, after groups and budget.
  final List<WorldInfoEntry> activated;

  /// The same entries bucketed by where they belong in the prompt.
  final Map<WorldInfoPosition, List<WorldInfoEntry>> byPosition;

  /// Entries that matched but lost the budget contest.
  final List<WorldInfoEntry> excludedByBudget;

  /// Entries that matched but lost an inclusion-group contest.
  final List<WorldInfoEntry> droppedByGroup;

  /// Tokens consumed by [activated].
  final int tokenCost;

  /// Timing state after this scan — carry it into the next turn.
  final WorldInfoTiming timing;

  bool get isEmpty => activated.isEmpty;

  /// Entries for one position, or empty.
  List<WorldInfoEntry> at(WorldInfoPosition position) =>
      byPosition[position] ?? const <WorldInfoEntry>[];

  String get debugSummary => 'activated ${activated.length} '
      '($tokenCost tokens), budget-dropped ${excludedByBudget.length}, '
      'group-dropped ${droppedByGroup.length}';
}

/// Decides which lorebook entries activate for a turn, and where they go.
///
/// Deliberately a pure function of its inputs plus the passed-in [WorldInfoTiming]:
/// it holds no state between calls, so a scan is reproducible and testable.
///
/// Implemented from SillyTavern's documented behaviour. Known simplifications,
/// which are choices rather than oversights:
///
/// - Inclusion groups resolve to the **highest `groupWeight`** with ties broken
///   by insertion order. SillyTavern picks weighted-randomly, which is not
///   reproducible; determinism matters more for a test suite.
/// - No embedding/vector retrieval (`vectorized`).
/// - No `automationId`-driven expansion, and no scanning of arbitrary prompt
///   blocks — the caller decides what text goes into [scan].
class WorldInfoScanner {
  WorldInfoScanner({
    this.tokenizer = const HeuristicTokenizer(),
    math.Random? random,
  }) : _random = random ?? math.Random();

  final Tokenizer tokenizer;
  final math.Random _random;

  /// Runs one turn's activation.
  ///
  /// [history] is oldest-first; the last [scanDepth] messages are searched.
  /// [scan] is extra text searched for every entry (character description,
  /// persona, scenario — whatever the caller wants eligible), matching
  /// SillyTavern's configurable scan surfaces.
  ///
  /// [tokenBudget] of 0 means unlimited. [recursionDepth] is the number of
  /// *additional* passes allowed, and only runs for books whose
  /// `recursiveScanning` flag is set.
  WorldInfoScanResult scan({
    required List<WorldInfoSource> sources,
    required List<ChatMessage> history,
    WorldInfoTiming? timing,
    String scan = '',
    int scanDepth = 2,
    int tokenBudget = 0,
    int recursionDepth = 1,
  }) {
    final state = timing ?? WorldInfoTiming();

    final candidates = <_Candidate>[
      for (final source in sources)
        for (final entry in source.book.entries)
          _Candidate(
            key: '${source.key}:${entry.uid}',
            entry: entry,
            recursionAllowed:
                source.book.recursiveScanning && !entry.excludeRecursion,
          ),
    ];

    // --- pass 0: key matching, constants, sticky carry-over -----------------
    final activated = <_Candidate>[];
    final activatedKeys = <String>{};
    // Entries kept alive purely by a sticky window. These must NOT re-arm that
    // window, or a sticky entry would never expire.
    final stickyContinuations = <String>{};

    for (final candidate in candidates) {
      final entryTiming = state[candidate.key];
      if (!candidate.entry.enabled) continue;
      if (candidate.entry.content.trim().isEmpty) continue;

      // Not yet eligible at all.
      if (entryTiming.isDelayed) continue;

      if (entryTiming.isSticky) {
        // Still burning down its sticky window, so it stays active with no key
        // match. If the key happens to match again, treat it as a fresh
        // activation so the window re-arms.
        final buffer = _scanBuffer(
          history,
          entry: candidate.entry,
          depth: scanDepth,
          extra: scan,
        );
        if (!_activates(candidate.entry, buffer)) {
          stickyContinuations.add(candidate.key);
        }
        activated.add(candidate);
        activatedKeys.add(candidate.key);
        continue;
      }

      if (entryTiming.isCoolingDown) continue;

      final buffer = _scanBuffer(history,
          entry: candidate.entry, depth: scanDepth, extra: scan);
      if (_activates(candidate.entry, buffer)) {
        activated.add(candidate);
        activatedKeys.add(candidate.key);
      }
    }

    // --- recursion passes --------------------------------------------------
    if (recursionDepth > 0) {
      for (var pass = 0; pass < recursionDepth; pass++) {
        final recursiveContext = StringBuffer()
          ..write(scan)
          ..write('\n')
          ..writeAll(
            activated.map((c) => c.entry.content),
            '\n',
          );
        final contextText = recursiveContext.toString();

        final newlyFound = <_Candidate>[];
        for (final candidate in candidates) {
          if (activatedKeys.contains(candidate.key)) continue;
          if (!candidate.recursionAllowed) continue;
          if (!candidate.entry.enabled) continue;
          if (candidate.entry.content.trim().isEmpty) continue;

          final entryTiming = state[candidate.key];
          if (entryTiming.isDelayed || entryTiming.isCoolingDown) continue;

          final buffer = _scanBuffer(
            history,
            entry: candidate.entry,
            depth: scanDepth,
            extra: contextText,
          );
          if (_activates(candidate.entry, buffer)) {
            newlyFound.add(candidate);
          }
        }

        if (newlyFound.isEmpty) break;
        for (final candidate in newlyFound) {
          activated.add(candidate);
          activatedKeys.add(candidate.key);
        }
      }
    }

    // --- inclusion groups: one winner per group ----------------------------
    final survivors = <_Candidate>[];
    final droppedByGroup = <WorldInfoEntry>[];
    final groups = <String, List<_Candidate>>{};

    for (final candidate in activated) {
      final group = candidate.entry.group;
      if (group == null || group.isEmpty) {
        survivors.add(candidate);
      } else {
        groups.putIfAbsent(group, () => <_Candidate>[]).add(candidate);
      }
    }

    for (final group in groups.values) {
      group.sort((a, b) {
        final byWeight = (b.entry.groupWeight ?? 0).compareTo(
          a.entry.groupWeight ?? 0,
        );
        if (byWeight != 0) return byWeight;
        return a.entry.insertionOrder.compareTo(b.entry.insertionOrder);
      });
      survivors.add(group.first);
      for (final loser in group.skip(1)) {
        droppedByGroup.add(loser.entry);
      }
    }

    // --- budget: lower insertionOrder is inserted higher, so it wins --------
    final ordered = survivors.toList()
      ..sort((a, b) {
        final byOrder =
            a.entry.insertionOrder.compareTo(b.entry.insertionOrder);
        if (byOrder != 0) return byOrder;
        return a.entry.uid.compareTo(b.entry.uid);
      });

    final included = <_Candidate>[];
    final excludedByBudget = <WorldInfoEntry>[];
    var tokenCost = 0;

    for (final candidate in ordered) {
      final cost = tokenizer.count(candidate.entry.content);
      if (tokenBudget > 0 && tokenCost + cost > tokenBudget) {
        excludedByBudget.add(candidate.entry);
        continue;
      }
      included.add(candidate);
      tokenCost += cost;
    }

    // --- arm counters for next turn ---------------------------------------
    state.advanceOneMessage();
    for (final candidate in included) {
      // A sticky continuation is already mid-window; arming it again would
      // make the entry immortal.
      if (stickyContinuations.contains(candidate.key)) continue;
      final entryTiming = state[candidate.key];
      if (candidate.entry.sticky > 0) {
        entryTiming.stickyLeft = candidate.entry.sticky;
      }
      if (candidate.entry.cooldown > 0) {
        entryTiming.cooldownLeft = candidate.entry.cooldown;
      }
    }

    // --- bucket by position ------------------------------------------------
    final byPosition = <WorldInfoPosition, List<WorldInfoEntry>>{};
    for (final candidate in included) {
      byPosition
          .putIfAbsent(candidate.entry.position, () => <WorldInfoEntry>[])
          .add(candidate.entry);
    }

    return WorldInfoScanResult(
      activated: <WorldInfoEntry>[for (final c in included) c.entry],
      byPosition: byPosition,
      excludedByBudget: excludedByBudget,
      droppedByGroup: droppedByGroup,
      tokenCost: tokenCost,
      timing: state,
    );
  }

  /// Builds the haystack an entry is matched against.
  ///
  /// Starts at the entry's own `scanDepth` (falling back to the caller's
  /// default when an entry leaves it at zero), searching the most recent
  /// messages first, then appends the caller's extra surface.
  String _scanBuffer(
    List<ChatMessage> history, {
    required WorldInfoEntry entry,
    required int depth,
    required String extra,
  }) {
    final effectiveDepth = entry.scanDepth > 0 ? entry.scanDepth : depth;

    final buffer = StringBuffer();
    if (extra.isNotEmpty) {
      buffer.write(extra);
      buffer.write('\n');
    }

    final start = history.length - effectiveDepth;
    for (var i = math.max(start, 0); i < history.length; i++) {
      buffer.write(history[i].content);
      buffer.write('\n');
    }
    return buffer.toString();
  }

  bool _activates(WorldInfoEntry entry, String buffer) {
    // Constant entries bypass key matching entirely.
    if (entry.constant) return true;
    if (entry.keys.isEmpty) return false;

    final primaryHit = entry.keys.any((key) => _matches(buffer, key, entry));
    if (!primaryHit) return false;

    if (entry.selective && entry.secondaryKeys.isNotEmpty) {
      final hits = <bool>[
        for (final key in entry.secondaryKeys) _matches(buffer, key, entry),
      ];
      final passes = switch (entry.selectiveLogic) {
        SelectiveLogic.andAny => hits.any((h) => h),
        SelectiveLogic.andAll => hits.every((h) => h),
        SelectiveLogic.notAny => !hits.any((h) => h),
        SelectiveLogic.notAll => !hits.every((h) => h),
      };
      if (!passes) return false;
    }

    if (entry.useProbability && entry.probability < 100) {
      if (entry.probability <= 0) return false;
      if (_random.nextInt(100) + 1 > entry.probability) return false;
    }

    return true;
  }

  bool _matches(String haystack, String needle, WorldInfoEntry entry) {
    if (needle.isEmpty) return false;
    if (haystack.isEmpty) return false;

    if (entry.useRegex) {
      try {
        return RegExp(
          needle,
          caseSensitive: entry.caseSensitive,
        ).hasMatch(haystack);
      } on FormatException {
        // An invalid pattern in a card must not take down the whole scan.
        return false;
      }
    }

    if (entry.matchWholeWords) {
      return RegExp(
        '\\b${RegExp.escape(needle)}\\b',
        caseSensitive: entry.caseSensitive,
      ).hasMatch(haystack);
    }

    if (entry.caseSensitive) return haystack.contains(needle);
    return haystack.toLowerCase().contains(needle.toLowerCase());
  }
}

class _Candidate {
  _Candidate({
    required this.key,
    required this.entry,
    required this.recursionAllowed,
  });

  final String key;
  final WorldInfoEntry entry;
  final bool recursionAllowed;
}
