/// Where a lorebook entry is injected into the prompt.
///
/// The numeric values are the wire format used by both the Character Card V2
/// `character_book` and SillyTavern's native world-info files, so they must not
/// be renumbered.
enum WorldInfoPosition {
  /// Before the character definitions (`worldInfoBefore`).
  beforeChar(0),

  /// After the character definitions (`worldInfoAfter`).
  afterChar(1),

  /// Top of the Author's Note.
  anTop(2),

  /// Bottom of the Author's Note.
  anBottom(3),

  /// Absolute injection into the message list, `depth` messages from the end.
  atDepth(4),

  /// Prepended to the example dialogue block.
  emTop(5),

  /// Appended to the example dialogue block.
  emBottom(6),

  /// Parked in a named outlet; only injected via an `{{outlet::Name}}` macro.
  outlet(7);

  const WorldInfoPosition(this.wire);

  final int wire;

  static WorldInfoPosition fromWire(Object? value) {
    final n = value is int ? value : int.tryParse('$value');
    for (final p in WorldInfoPosition.values) {
      if (p.wire == n) return p;
    }
    return WorldInfoPosition.beforeChar;
  }
}

/// How a secondary-key match combines with the primary match.
enum SelectiveLogic {
  andAny(0),
  notAll(1),
  notAny(2),
  andAll(3);

  const SelectiveLogic(this.wire);

  final int wire;

  static SelectiveLogic fromWire(Object? value) {
    final n = value is int ? value : int.tryParse('$value');
    for (final l in SelectiveLogic.values) {
      if (l.wire == n) return l;
    }
    return SelectiveLogic.andAny;
  }
}

/// One lorebook entry.
///
/// Field names follow SillyTavern's native world-info schema; several carry a
/// legacy alias (`key`/`keys`, `order`/`insertion_order`) and both spellings are
/// read here, because files in the wild use each.
class WorldInfoEntry {
  WorldInfoEntry({
    required this.uid,
    required this.keys,
    required this.secondaryKeys,
    required this.content,
    required this.comment,
    required this.enabled,
    required this.constant,
    required this.selective,
    required this.selectiveLogic,
    required this.caseSensitive,
    required this.matchWholeWords,
    required this.useRegex,
    required this.insertionOrder,
    required this.position,
    required this.depth,
    required this.probability,
    required this.useProbability,
    required this.scanDepth,
    required this.role,
    required this.group,
    required this.groupWeight,
    required this.outletName,
    required this.sticky,
    required this.cooldown,
    required this.delay,
    required this.excludeRecursion,
    required this.preventRecursion,
    required this.delayUntilRecursion,
    required this.extensions,
    required this.raw,
  });

  final int uid;
  final List<String> keys;
  final List<String> secondaryKeys;
  final String content;
  final String comment;

  /// True when this entry may activate. Native files express this inverted, as
  /// `disable`.
  final bool enabled;

  /// Always injected, regardless of key matches.
  final bool constant;

  /// Require a secondary-key match before activating.
  final bool selective;
  final SelectiveLogic selectiveLogic;
  final bool caseSensitive;
  final bool matchWholeWords;
  final bool useRegex;

  /// Lower sorts higher in the prompt.
  final int insertionOrder;
  final WorldInfoPosition position;

  /// Message depth for [WorldInfoPosition.atDepth].
  final int depth;

  /// Activation chance, 0-100.
  final int probability;
  final bool useProbability;

  /// How many recent messages are scanned for this entry's keys.
  final int scanDepth;

  /// Chat role for depth injections: `system`, `user` or `assistant`.
  final String role;

  /// Inclusion group; only one entry per group activates.
  final String? group;
  final int? groupWeight;
  final String? outletName;

  /// Remain active for N further messages once triggered.
  final int sticky;

  /// Cannot re-activate for N messages after firing.
  final int cooldown;

  /// Becomes eligible only after N messages.
  final int delay;

  final bool excludeRecursion;
  final bool preventRecursion;
  final bool delayUntilRecursion;

  final Map<String, dynamic> extensions;

  /// The source object, preserved verbatim.
  final Map<String, dynamic> raw;

  /// True when this entry can contribute text to a prompt at all.
  bool get contributes => enabled && content.trim().isNotEmpty;

  factory WorldInfoEntry.fromJson(int fallbackUid, Map<String, dynamic> json) {
    int intOf(List<String> names, int fallback) {
      for (final name in names) {
        final v = json[name];
        if (v is int) return v;
        if (v is num) return v.toInt();
        if (v is String) {
          final parsed = int.tryParse(v);
          if (parsed != null) return parsed;
        }
      }
      return fallback;
    }

    bool boolOf(List<String> names, bool fallback) {
      for (final name in names) {
        final v = json[name];
        if (v is bool) return v;
        if (v is String) {
          if (v.toLowerCase() == 'true') return true;
          if (v.toLowerCase() == 'false') return false;
        }
      }
      return fallback;
    }

    String stringOf(List<String> names, String fallback) {
      for (final name in names) {
        final v = json[name];
        if (v is String) return v;
      }
      return fallback;
    }

    // Native files invert this: `disable: true` means disabled.
    final disabled = boolOf(<String>['disable'], false);
    final enabled = disabled ? false : boolOf(<String>['enabled'], true);

    final group = json['group'];
    final groupWeight = json['groupWeight'];
    final outlet = json['outletName'] ?? json['outlet_name'];

    return WorldInfoEntry(
      uid: intOf(<String>['uid'], fallbackUid),
      keys: _stringList(json['key'] ?? json['keys'] ?? json['primary_keys']),
      secondaryKeys:
          _stringList(json['keysecondary'] ?? json['secondary_keys']),
      content: stringOf(<String>['content'], ''),
      comment: stringOf(<String>['comment', 'addMemo', 'name'], ''),
      enabled: enabled,
      constant: boolOf(<String>['constant'], false),
      selective: boolOf(<String>['selective'], false),
      selectiveLogic: SelectiveLogic.fromWire(json['selectiveLogic']),
      caseSensitive: boolOf(<String>['caseSensitive', 'case_sensitive'], false),
      matchWholeWords: boolOf(<String>['matchWholeWords'], false),
      useRegex: boolOf(<String>['useRegex', 'regex'], false),
      insertionOrder: intOf(<String>['order', 'insertion_order'], 100),
      position: WorldInfoPosition.fromWire(json['position']),
      depth: intOf(<String>['depth'], 4),
      probability: intOf(<String>['probability'], 100),
      useProbability: boolOf(<String>['useProbability'], true),
      scanDepth: intOf(<String>['scanDepth', 'scan_depth'], 2),
      role: stringOf(<String>['role'], 'system'),
      group: group is String && group.isNotEmpty ? group : null,
      groupWeight: groupWeight is int ? groupWeight : null,
      outletName: outlet is String && outlet.isNotEmpty ? outlet : null,
      sticky: intOf(<String>['sticky'], 0),
      cooldown: intOf(<String>['cooldown'], 0),
      delay: intOf(<String>['delay'], 0),
      excludeRecursion: boolOf(<String>['excludeRecursion'], false),
      preventRecursion: boolOf(<String>['preventRecursion'], false),
      delayUntilRecursion: boolOf(<String>['delayUntilRecursion'], false),
      extensions: json['extensions'] is Map
          ? Map<String, dynamic>.from(json['extensions'] as Map)
          : <String, dynamic>{},
      raw: json,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        ...raw,
        'uid': uid,
        'key': keys,
        'keysecondary': secondaryKeys,
        'content': content,
        'comment': comment,
        'disable': !enabled,
        'constant': constant,
        'selective': selective,
        'selectiveLogic': selectiveLogic.wire,
        'order': insertionOrder,
        'position': position.wire,
        'depth': depth,
        'probability': probability,
        'useProbability': useProbability,
        'scanDepth': scanDepth,
        'role': role,
      };

  @override
  String toString() =>
      'WorldInfoEntry(uid: $uid, keys: $keys, pos: ${position.name}'
      '${constant ? ', constant' : ''}${enabled ? '' : ', disabled'})';
}

/// A lorebook, as embedded in a V2/V3 card (`character_book`).
///
/// V2 stores entries as an ordered **array**; SillyTavern's native files store
/// them as an **object keyed by the uid as a string**. Both load through here.
class CharacterBook {
  CharacterBook({
    required this.name,
    required this.description,
    required this.scanDepth,
    required this.tokenBudget,
    required this.recursiveScanning,
    required this.entries,
    required this.extensions,
    required this.raw,
  });

  final String name;
  final String description;
  final int? scanDepth;
  final int? tokenBudget;
  final bool recursiveScanning;
  final List<WorldInfoEntry> entries;
  final Map<String, dynamic> extensions;
  final Map<String, dynamic> raw;

  factory CharacterBook.fromJson(Map<String, dynamic> json) {
    final rawEntries = json['entries'];
    final entries = <WorldInfoEntry>[];

    if (rawEntries is List) {
      for (var i = 0; i < rawEntries.length; i++) {
        final item = rawEntries[i];
        if (item is Map) {
          entries.add(
            WorldInfoEntry.fromJson(i, Map<String, dynamic>.from(item)),
          );
        }
      }
    } else if (rawEntries is Map) {
      // Native layout: {"0": {...}, "1": {...}} — the key must equal String(uid)
      // or SillyTavern's editor never renders the entry. Preserved as-is.
      rawEntries.forEach((key, value) {
        if (value is Map) {
          final fallback = int.tryParse('$key') ?? entries.length;
          entries.add(
            WorldInfoEntry.fromJson(fallback, Map<String, dynamic>.from(value)),
          );
        }
      });
    }

    return CharacterBook(
      name: _asString(json['name']),
      description: _asString(json['description']),
      scanDepth: _asInt(json['scan_depth']),
      tokenBudget: _asInt(json['token_budget']),
      recursiveScanning: json['recursive_scanning'] == true,
      entries: entries,
      extensions: json['extensions'] is Map
          ? Map<String, dynamic>.from(json['extensions'] as Map)
          : <String, dynamic>{},
      raw: json,
    );
  }

  /// Parses SillyTavern's native world-info file shape.
  factory CharacterBook.fromNativeJson(Map<String, dynamic> json) {
    if (!json.containsKey('entries')) {
      throw FormatException(
        'not a world-info file: no "entries" key at the root',
      );
    }
    return CharacterBook.fromJson(json);
  }

  /// Entries that are enabled and carry text.
  List<WorldInfoEntry> get active => <WorldInfoEntry>[
        for (final e in entries)
          if (e.contributes) e
      ];

  Map<String, dynamic> toJson() => <String, dynamic>{
        ...raw,
        if (name.isNotEmpty) 'name': name,
        if (description.isNotEmpty) 'description': description,
        if (scanDepth != null) 'scan_depth': scanDepth,
        if (tokenBudget != null) 'token_budget': tokenBudget,
        'recursive_scanning': recursiveScanning,
        'extensions': extensions,
        'entries': <Map<String, dynamic>>[
          for (final e in entries) e.toJson(),
        ],
      };

  @override
  String toString() =>
      'CharacterBook("$name", ${entries.length} entries, ${active.length} active)';
}

List<String> _stringList(Object? value) {
  if (value is String) return value.isEmpty ? <String>[] : <String>[value];
  if (value is List) {
    return <String>[
      for (final item in value)
        if (item is String) item,
    ];
  }
  return <String>[];
}

String _asString(Object? value) => value is String ? value : '';

int? _asInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}
