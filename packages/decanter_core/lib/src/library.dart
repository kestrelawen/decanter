import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'character_card.dart';
import 'chat.dart';

/// One character saved in the library.
///
/// A summary, not the card itself: the listing reads these without parsing full
/// cards, so a library of a hundred characters opens instantly.
class LibraryEntry {
  const LibraryEntry({
    required this.id,
    required this.name,
    this.creator = '',
    this.fileName = '',
    this.preview = '',
    this.greetingCount = 1,
    this.loreCount = 0,
    this.spec = '',
    this.importedAt,
  });

  /// Stable directory name, derived from the character's name.
  final String id;

  final String name;
  final String creator;

  /// The file the card was imported from, for the user's benefit.
  final String fileName;

  /// A short excerpt of the description, for the library row.
  final String preview;

  /// Includes the first message, so 1 means "no alternates".
  final int greetingCount;

  final int loreCount;

  /// Which card spec the source declared, e.g. `chara_card_v3`.
  final String spec;

  final DateTime? importedAt;

  bool get hasAlternateGreetings => greetingCount > 1;

  LibraryEntry copyWith({DateTime? importedAt}) => LibraryEntry(
        id: id,
        name: name,
        creator: creator,
        fileName: fileName,
        preview: preview,
        greetingCount: greetingCount,
        loreCount: loreCount,
        spec: spec,
        importedAt: importedAt ?? this.importedAt,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'version': 1,
        'id': id,
        'name': name,
        'creator': creator,
        'fileName': fileName,
        'preview': preview,
        'greetingCount': greetingCount,
        'loreCount': loreCount,
        'spec': spec,
        'importedAt': importedAt?.toIso8601String(),
      };

  factory LibraryEntry.fromJson(Map<String, dynamic> json) => LibraryEntry(
        id: json['id'] is String ? json['id'] as String : '',
        name: json['name'] is String ? json['name'] as String : 'Unnamed',
        creator: json['creator'] is String ? json['creator'] as String : '',
        fileName: json['fileName'] is String ? json['fileName'] as String : '',
        preview: json['preview'] is String ? json['preview'] as String : '',
        greetingCount:
            json['greetingCount'] is int ? json['greetingCount'] as int : 1,
        loreCount: json['loreCount'] is int ? json['loreCount'] as int : 0,
        spec: json['spec'] is String ? json['spec'] as String : '',
        importedAt: json['importedAt'] is String
            ? DateTime.tryParse(json['importedAt'] as String)
            : null,
      );

  @override
  String toString() => 'LibraryEntry($id, "$name")';
}

/// A conversation as stored on disk.
class StoredChat {
  const StoredChat({this.messages = const <ChatMessage>[], this.savedAt});

  final List<ChatMessage> messages;
  final DateTime? savedAt;

  bool get isEmpty => messages.isEmpty;
  int get messageCount => messages.length;
}

/// Cards and conversations, kept as plain files under one directory.
///
/// The root is injected rather than looked up, so this whole class is testable
/// from a temporary directory on a machine with no device — which is the only
/// reason the storage layer is not the least-verified part of the app.
///
/// Reads are synchronous. At this scale (a handful of small JSON files) the
/// difference is unmeasurable and the API stays simple enough to reason about;
/// it would need revisiting before a library of thousands.
class LibraryStore {
  LibraryStore(this.root);

  final Directory root;

  static const String _cardsDirName = 'cards';
  static const String _chatsDirName = 'chats';
  static const String _metaName = 'meta.json';
  static const String _cardName = 'card.json';
  static const int chatFormatVersion = 1;

  Directory get cardsDirectory => Directory('${root.path}/$_cardsDirName');
  Directory get chatsDirectory => Directory('${root.path}/$_chatsDirName');

  Directory _cardDirectory(String id) =>
      Directory('${cardsDirectory.path}/$id');
  File _chatFile(String id) => File('${chatsDirectory.path}/$id.json');

  void ensureDirectories() {
    cardsDirectory.createSync(recursive: true);
    chatsDirectory.createSync(recursive: true);
  }

  /// Every stored card, newest import first.
  ///
  /// A card whose metadata cannot be read is skipped rather than thrown: one
  /// corrupted file must not make the rest of someone's library unreachable.
  List<LibraryEntry> list() {
    ensureDirectories();
    final List<LibraryEntry> entries = <LibraryEntry>[];

    for (final FileSystemEntity entity in cardsDirectory.listSync()) {
      if (entity is! Directory) continue;
      final File meta = File('${entity.path}/$_metaName');
      if (!meta.existsSync()) continue;
      try {
        final Object? decoded = jsonDecode(meta.readAsStringSync());
        if (decoded is Map) {
          final LibraryEntry entry = LibraryEntry.fromJson(
            Map<String, dynamic>.from(decoded),
          );
          if (entry.id.isNotEmpty) entries.add(entry);
        }
      } on Object {
        continue;
      }
    }

    entries.sort((LibraryEntry a, LibraryEntry b) {
      final DateTime? at = a.importedAt;
      final DateTime? bt = b.importedAt;
      if (at != null && bt != null) {
        final int byTime = bt.compareTo(at);
        if (byTime != 0) return byTime;
      } else if (at != null) {
        return -1;
      } else if (bt != null) {
        return 1;
      }
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });

    return entries;
  }

  LibraryEntry? find(String id) {
    for (final LibraryEntry entry in list()) {
      if (entry.id == id) return entry;
    }
    return null;
  }

  bool exists(String id) => _cardDirectory(id).existsSync();

  /// Loads the stored card, with every unmodelled key preserved.
  TavernCard loadCard(String id) {
    final File file = File('${_cardDirectory(id).path}/$_cardName');
    if (!file.existsSync()) {
      throw CardFormatException('No card stored under "$id".');
    }
    final Object? decoded = jsonDecode(file.readAsStringSync());
    if (decoded is! Map) {
      throw CardFormatException('Stored card "$id" is not a JSON object.');
    }
    return TavernCard.fromJson(Map<String, dynamic>.from(decoded));
  }

  /// The untouched bytes the card was imported from, if they were kept.
  File? sourceFile(String id) {
    final Directory directory = _cardDirectory(id);
    if (!directory.existsSync()) return null;
    for (final FileSystemEntity entity in directory.listSync()) {
      final String name = entity.path.split(Platform.pathSeparator).last;
      if (name.startsWith('source.')) return File(entity.path);
    }
    return null;
  }

  /// The card's own picture, when it was imported from one.
  ///
  /// A PNG card embeds the card inside an image chunk, so the source file *is*
  /// the portrait. A JSON card has no picture at all, and that is a normal
  /// outcome rather than an error — the library falls back to initials.
  File? imageFile(String id) {
    final File? source = sourceFile(id);
    if (source == null) return null;
    final String path = source.path.toLowerCase();
    const List<String> imageExtensions = <String>[
      '.png',
      '.jpg',
      '.jpeg',
      '.webp',
      '.gif',
      '.bmp',
    ];
    for (final String extension in imageExtensions) {
      if (path.endsWith(extension)) return source;
    }
    return null;
  }

  /// Stores a card from raw bytes and returns its new library entry.
  ///
  /// Throws [CardFormatException] when the bytes are not a character card, so
  /// the caller can show an explanation instead of importing junk.
  LibraryEntry importCard({required Uint8List bytes, String fileName = ''}) {
    final TavernCard card = decodeCardBytes(bytes, fileName: fileName);
    ensureDirectories();

    final String stem =
        card.name.trim().isEmpty ? _stemOf(fileName) : card.name;
    final String id = _uniqueId(slugify(stem));
    final Directory directory = _cardDirectory(id)..createSync(recursive: true);

    _writeAtomically(
      File('${directory.path}/$_cardName'),
      const JsonEncoder.withIndent('  ').convert(card.toJson()),
    );

    // The original is kept, not just the parsed form: a PNG card's image is part
    // of the card, and recovering it later would need the bytes we would
    // otherwise have discarded here.
    File(
      '${directory.path}/source${_extensionFor(bytes, fileName)}',
    ).writeAsBytesSync(bytes);

    final LibraryEntry entry = LibraryEntry(
      id: id,
      name: card.name.trim().isEmpty ? _stemOf(fileName) : card.name.trim(),
      creator: card.creator,
      fileName: fileName,
      preview: _preview(card.description),
      greetingCount: card.greetings.length,
      loreCount: card.characterBook?.entries.length ?? 0,
      spec: card.spec.id,
      importedAt: DateTime.now(),
    );

    _writeAtomically(
      File('${directory.path}/$_metaName'),
      jsonEncode(entry.toJson()),
    );

    return entry;
  }

  /// Removes a card and its conversation.
  void delete(String id) {
    final Directory directory = _cardDirectory(id);
    if (directory.existsSync()) directory.deleteSync(recursive: true);
    final File chat = _chatFile(id);
    if (chat.existsSync()) chat.deleteSync();
  }

  bool hasChat(String id) => _chatFile(id).existsSync();

  StoredChat loadChat(String id) {
    final File file = _chatFile(id);
    if (!file.existsSync()) return const StoredChat();
    try {
      final Object? decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! Map) return const StoredChat();
      final Map<String, dynamic> map = Map<String, dynamic>.from(decoded);
      final Object? rawMessages = map['messages'];
      return StoredChat(
        messages: <ChatMessage>[
          if (rawMessages is List)
            for (final Object? raw in rawMessages)
              if (raw is Map)
                ChatMessage.fromJson(Map<String, dynamic>.from(raw)),
        ],
        savedAt: map['savedAt'] is String
            ? DateTime.tryParse(map['savedAt'] as String)
            : null,
      );
    } on Object {
      // A half-written or corrupt chat is not worth failing a launch over; the
      // card still opens, just with a fresh conversation.
      return const StoredChat();
    }
  }

  void saveChat(String id, List<ChatMessage> messages) {
    ensureDirectories();
    _writeAtomically(
      _chatFile(id),
      jsonEncode(<String, dynamic>{
        'version': chatFormatVersion,
        'savedAt': DateTime.now().toIso8601String(),
        'messages': <Map<String, dynamic>>[
          for (final ChatMessage message in messages) message.toJson(),
        ],
      }),
    );
  }

  void clearChat(String id) {
    final File file = _chatFile(id);
    if (file.existsSync()) file.deleteSync();
  }

  /// Writes by way of a temporary file and a rename.
  ///
  /// A process killed mid-write then leaves the previous good file in place
  /// rather than a truncated one, which for a JSON document means the difference
  /// between a stale chat and an unreadable one.
  void _writeAtomically(File target, String contents) {
    target.parent.createSync(recursive: true);
    final File temporary = File('${target.path}.tmp');
    temporary.writeAsStringSync(contents, flush: true);
    if (target.existsSync()) target.deleteSync();
    temporary.renameSync(target.path);
  }

  String _uniqueId(String stem) {
    final String base = stem.isEmpty ? 'card' : stem;
    if (!exists(base)) return base;
    for (var suffix = 2; suffix < 10000; suffix++) {
      final String candidate = '$base-$suffix';
      if (!exists(candidate)) return candidate;
    }
    return '$base-${DateTime.now().microsecondsSinceEpoch}';
  }
}

/// Parses card bytes that may be a PNG (with an embedded card) or bare JSON.
///
/// PNG cards are the format the ecosystem actually shares, but a JSON export is
/// equally valid and users do have them, so both are accepted.
TavernCard decodeCardBytes(Uint8List bytes, {String fileName = ''}) {
  if (_looksLikePng(bytes)) return TavernCard.fromPng(bytes);

  final String text;
  try {
    text = utf8.decode(bytes);
  } on FormatException {
    throw CardFormatException(
      'This file is neither a PNG nor valid text'
      '${fileName.isEmpty ? '' : ' ($fileName)'}. Character cards are usually '
      'a PNG with the card embedded, or a .json export.',
    );
  }

  final String trimmed = text.trimLeft();
  if (!trimmed.startsWith('{')) {
    if (trimmed.startsWith('PK')) {
      throw CardFormatException(
        'This looks like a .charx archive, which is not supported yet. Export '
        'the character as PNG or JSON instead.',
      );
    }
    throw CardFormatException(
      'This does not look like a character card: expected a PNG or a JSON '
      'object${fileName.isEmpty ? '' : ' (got $fileName)'}.',
    );
  }

  final Object? decoded = jsonDecode(text);
  if (decoded is! Map) {
    throw CardFormatException('The card file is not a JSON object.');
  }
  return TavernCard.fromJson(Map<String, dynamic>.from(decoded));
}

/// Turns a character name into a directory-safe identifier.
///
/// Kept readable rather than hashed, because a library whose folders are named
/// after the characters is one a person can inspect and repair.
String slugify(String input) {
  final String lowered = input.trim().toLowerCase();
  final StringBuffer out = StringBuffer();
  var lastWasDash = false;

  for (final int rune in lowered.runes) {
    final String character = String.fromCharCode(rune);
    final bool keep = RegExp(r'[a-z0-9]').hasMatch(character);
    if (keep) {
      out.write(character);
      lastWasDash = false;
    } else if (!lastWasDash && out.isNotEmpty) {
      out.write('-');
      lastWasDash = true;
    }
  }

  var result = out.toString();
  while (result.endsWith('-')) {
    result = result.substring(0, result.length - 1);
  }
  if (result.length > 48) result = result.substring(0, 48);
  while (result.endsWith('-')) {
    result = result.substring(0, result.length - 1);
  }
  return result;
}

bool _looksLikePng(Uint8List bytes) {
  const List<int> signature = <int>[137, 80, 78, 71, 13, 10, 26, 10];
  if (bytes.length < signature.length) return false;
  for (var i = 0; i < signature.length; i++) {
    if (bytes[i] != signature[i]) return false;
  }
  return true;
}

String _extensionFor(Uint8List bytes, String fileName) {
  if (_looksLikePng(bytes)) return '.png';
  final int dot = fileName.lastIndexOf('.');
  if (dot != -1 && dot < fileName.length - 1) {
    final String extension = fileName.substring(dot).toLowerCase();
    if (RegExp(r'^\.[a-z0-9]{1,8}$').hasMatch(extension)) return extension;
  }
  return '.json';
}

String _stemOf(String fileName) {
  final String base = fileName.split(RegExp(r'[/\\]')).last;
  final int dot = base.lastIndexOf('.');
  final String stem = dot > 0 ? base.substring(0, dot) : base;
  final String slug = slugify(stem);
  return slug.isEmpty ? 'card' : slug;
}

/// The first couple of lines of the description, whitespace collapsed.
String _preview(String description) {
  final String collapsed = description.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (collapsed.length <= 160) return collapsed;
  return '${collapsed.substring(0, 157)}…';
}
