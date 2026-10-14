import 'dart:convert';
import 'dart:typed_data';

import 'png_text.dart';
import 'world_info.dart';

/// Which revision of the character-card spec a card is written in.
enum CardSpec {
  v1('chara_card_v1', '1.0'),
  v2('chara_card_v2', '2.0'),
  v3('chara_card_v3', '3.0');

  const CardSpec(this.id, this.version);

  /// The value of the card's top-level `spec` field.
  final String id;

  /// The spec revision this implementation writes for [id].
  final String version;

  static CardSpec? fromId(Object? id) {
    for (final spec in CardSpec.values) {
      if (spec.id == id) return spec;
    }
    return null;
  }
}

class CardFormatException implements Exception {
  CardFormatException(this.message);

  final String message;

  @override
  String toString() => 'CardFormatException: $message';
}

/// A parsed character card, normalised across V1, V2 and V3.
///
/// V1 cards have no top-level `data`; V2 and V3 wrap everything in `data`. This
/// class always exposes the V1-compatible fields at the top level *and* keeps
/// the untouched source document in [raw], so nothing an author wrote is lost.
class TavernCard {
  TavernCard({
    required this.spec,
    required this.specVersion,
    required this.name,
    required this.description,
    required this.personality,
    required this.scenario,
    required this.firstMes,
    required this.mesExample,
    required this.creatorNotes,
    required this.systemPrompt,
    required this.postHistoryInstructions,
    required this.alternateGreetings,
    required this.tags,
    required this.creator,
    required this.characterVersion,
    required this.extensions,
    required this.characterBook,
    required this.raw,
    required this.dataExtras,
  });

  final CardSpec spec;
  final String specVersion;

  // V1-compatible fields.
  final String name;
  final String description;
  final String personality;
  final String scenario;
  final String firstMes;
  final String mesExample;

  // V2+ fields.
  final String creatorNotes;
  final String systemPrompt;
  final String postHistoryInstructions;
  final List<String> alternateGreetings;
  final List<String> tags;
  final String creator;
  final String characterVersion;
  final Map<String, dynamic> extensions;
  final CharacterBook? characterBook;

  /// The source document exactly as parsed. Never mutated.
  final Map<String, dynamic> raw;

  /// Keys inside `data` this version does not model, preserved for re-export.
  final Map<String, dynamic> dataExtras;

  /// The primary opening turn.
  String get greeting => firstMes;

  /// Every greeting this card offers: the first message plus alternates.
  List<String> get greetings => <String>[
        if (firstMes.isNotEmpty) firstMes,
        ...alternateGreetings,
      ];

  /// The lorebook linked via `data.extensions.world`, if the card names one.
  String? get linkedWorldName {
    final world = extensions['world'];
    return world is String && world.isNotEmpty ? world : null;
  }

  /// Parses a card from its decoded JSON object.
  ///
  /// A document with no `spec` field — or with `spec: chara_card_v1` — is
  /// treated as V1 and hoisted, which is what SillyTavern's `getCharaCardV2`
  /// does for legacy cards.
  factory TavernCard.fromJson(Map<String, dynamic> json) {
    final spec = CardSpec.fromId(json['spec']) ?? CardSpec.v1;

    final Map<String, dynamic> data;
    if (spec == CardSpec.v1) {
      // Legacy layout: fields live at the top level.
      data = json;
    } else {
      final rawData = json['data'];
      if (rawData is! Map) {
        throw CardFormatException(
          'card declares spec "${json['spec']}" but has no "data" object',
        );
      }
      data = Map<String, dynamic>.from(rawData);
    }

    final consumed = <String>{};
    T take<T>(String key, T fallback) {
      consumed.add(key);
      final value = data[key];
      return value is T ? value : fallback;
    }

    final extensions = _stringKeyedMap(data['extensions']);
    consumed.add('extensions');

    final rawBook = data['character_book'];
    consumed.add('character_book');

    // Marked consumed before the constructor runs, because dataExtras is built
    // from this set inside it. Missing these would duplicate the fields on
    // round-trip and let a bare-string alternate_greetings survive as a string.
    consumed.add('alternate_greetings');
    consumed.add('tags');
    consumed.add('spec');
    consumed.add('spec_version');

    final card = TavernCard(
      spec: spec,
      specVersion: take<String>('spec_version', spec.version),
      name: take<String>('name', ''),
      description: take<String>('description', ''),
      personality: take<String>('personality', ''),
      scenario: take<String>('scenario', ''),
      firstMes: take<String>('first_mes', ''),
      mesExample: take<String>('mes_example', ''),
      creatorNotes: take<String>('creator_notes', ''),
      systemPrompt: take<String>('system_prompt', ''),
      postHistoryInstructions: take<String>('post_history_instructions', ''),
      alternateGreetings: _stringList(data['alternate_greetings']),
      tags: _stringList(data['tags']),
      creator: take<String>('creator', ''),
      characterVersion: take<String>('character_version', ''),
      extensions: extensions,
      characterBook: rawBook is Map
          ? CharacterBook.fromJson(Map<String, dynamic>.from(rawBook))
          : null,
      raw: json,
      dataExtras: <String, dynamic>{
        for (final entry in data.entries)
          if (!consumed.contains(entry.key)) entry.key: entry.value,
      },
    );
    return card;
  }

  /// Parses a card out of a PNG carrying a `chara` or `ccv3` tEXt chunk.
  ///
  /// Throws [CardFormatException] when no card chunk is present, so callers can
  /// distinguish "not a card image" from "corrupt card".
  factory TavernCard.fromPng(Uint8List bytes) {
    final String? jsonString;
    try {
      jsonString = findCardJsonString(bytes);
    } on PngFormatException catch (e) {
      throw CardFormatException('PNG could not be read: ${e.message}');
    } on FormatException catch (e) {
      // Base64 or UTF-8 decoding inside the chunk failed. Callers only catch
      // CardFormatException, so a malformed payload must not leak a bare
      // FormatException out of here.
      throw CardFormatException(
          'card chunk could not be decoded: ${e.message}');
    }
    if (jsonString == null) {
      throw CardFormatException(
        'PNG has no character card chunk (looked for '
        '${tavernCardKeywords.join(", ")})',
      );
    }
    return TavernCard.fromJson(_decodeObject(jsonString));
  }

  /// Serialises back to a V2 document, re-emitting unmodelled keys.
  ///
  /// Round-tripping is lossless: anything original that this class does not
  /// model is written back from [dataExtras].
  Map<String, dynamic> toJson() {
    final data = <String, dynamic>{
      'name': name,
      'description': description,
      'personality': personality,
      'scenario': scenario,
      'first_mes': firstMes,
      'mes_example': mesExample,
      'creator_notes': creatorNotes,
      'system_prompt': systemPrompt,
      'post_history_instructions': postHistoryInstructions,
      'alternate_greetings': alternateGreetings,
      'tags': tags,
      'creator': creator,
      'character_version': characterVersion,
      'extensions': extensions,
      if (characterBook != null) 'character_book': characterBook!.toJson(),
      // Unmodelled V3-and-later keys survive the round trip.
      ...dataExtras,
    };
    return <String, dynamic>{
      'spec': CardSpec.v2.id,
      'spec_version': specVersion,
      'data': data,
    };
  }

  @override
  String toString() =>
      'TavernCard(${spec.id}, "$name", ${alternateGreetings.length} alt greetings'
      '${characterBook == null ? '' : ', book "${characterBook!.name}"'})';
}

Map<String, dynamic> _decodeObject(String jsonString) {
  final Object? decoded;
  try {
    decoded = jsonDecode(jsonString);
  } on FormatException catch (e) {
    throw CardFormatException('card payload is not valid JSON: ${e.message}');
  }
  if (decoded is! Map) {
    throw CardFormatException(
      'card payload is a ${decoded.runtimeType}, expected a JSON object',
    );
  }
  return Map<String, dynamic>.from(decoded);
}

/// Normalises a field that the specs allow to be either a string or a list.
///
/// V2 states `alternate_greetings` accepts a string from some sources and must
/// be normalised to an array.
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

Map<String, dynamic> _stringKeyedMap(Object? value) {
  if (value is Map) return Map<String, dynamic>.from(value);
  return <String, dynamic>{};
}
