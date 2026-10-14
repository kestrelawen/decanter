import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// A known OpenAI-compatible endpoint, offered as a one-tap preset.
///
/// BYOK lives or dies on this list: someone who has to hand-type a base URL and
/// a model name will mostly give up before their first reply.
class BackendPreset {
  const BackendPreset({
    required this.label,
    required this.baseUrl,
    required this.defaultModel,
    this.note,
  });

  final String label;
  final String baseUrl;
  final String defaultModel;
  final String? note;

  static const List<BackendPreset> all = <BackendPreset>[
    BackendPreset(
      label: 'OpenAI',
      baseUrl: 'https://api.openai.com/v1',
      defaultModel: 'gpt-4o-mini',
    ),
    BackendPreset(
      label: 'OpenRouter',
      baseUrl: 'https://openrouter.ai/api/v1',
      defaultModel: 'anthropic/claude-3.5-sonnet',
      note: 'Many models behind one key.',
    ),
    BackendPreset(
      label: 'DeepSeek',
      baseUrl: 'https://api.deepseek.com/v1',
      defaultModel: 'deepseek-chat',
    ),
    BackendPreset(
      label: 'Groq',
      baseUrl: 'https://api.groq.com/openai/v1',
      defaultModel: 'llama-3.3-70b-versatile',
    ),
    BackendPreset(
      label: 'Local (Ollama)',
      baseUrl: 'http://10.0.2.2:11434/v1',
      defaultModel: 'llama3.1',
      note: '10.0.2.2 reaches your host machine from an emulator.',
    ),
    BackendPreset(
      label: 'Local (LM Studio)',
      baseUrl: 'http://10.0.2.2:1234/v1',
      defaultModel: 'local-model',
    ),
  ];
}

/// A distinct persona profile representing the user in conversation.
class PersonaProfile {
  const PersonaProfile({
    required this.id,
    required this.name,
    this.description = '',
    this.avatarPath,
  });

  final String id;
  final String name;
  final String description;
  final String? avatarPath;

  PersonaProfile copyWith({
    String? id,
    String? name,
    String? description,
    String? avatarPath,
    bool clearAvatar = false,
  }) =>
      PersonaProfile(
        id: id ?? this.id,
        name: name ?? this.name,
        description: description ?? this.description,
        avatarPath: clearAvatar ? null : (avatarPath ?? this.avatarPath),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'description': description,
        if (avatarPath != null) 'avatarPath': avatarPath,
      };

  factory PersonaProfile.fromJson(Map<String, dynamic> json) => PersonaProfile(
        id: json['id'] is String ? json['id'] as String : 'p_default',
        name: json['name'] is String ? json['name'] as String : 'You',
        description:
            json['description'] is String ? json['description'] as String : '',
        avatarPath: json['avatarPath'] as String?,
      );
}

/// Everything the app persists about the user's setup.
class AppSettings {
  const AppSettings({
    this.baseUrl = 'https://api.openai.com/v1',
    this.apiKey = '',
    this.model = 'gpt-4o-mini',
    this.temperature = 0.9,
    this.maxTokens,
    this.personaName = 'You',
    this.personaDescription = '',
    this.personas = const <PersonaProfile>[],
    this.activePersonaId = '',
    this.authorNote = '',
    this.contextBudget = 32768,
    this.updateRepo = 'kestrelawen/decanter',
    this.updateToken = '',
  });

  final String baseUrl;
  final String apiKey;
  final String model;

  final double temperature;
  final int? maxTokens;

  final String personaName;
  final String personaDescription;

  /// Stored persona profiles for quick switching.
  final List<PersonaProfile> personas;

  /// Identifier of the currently active persona.
  final String activePersonaId;

  /// Injected into the chat at depth. Empty means no note.
  final String authorNote;

  /// Token ceiling for the assembled prompt. 0 disables trimming.
  final int contextBudget;

  /// `owner/name` of the GitHub repository the updater reads releases from.
  final String updateRepo;

  /// Read-only GitHub token. Needed only while the repository is private:
  /// GitHub answers 404 for a private repository to an unauthenticated client,
  /// so the updater cannot tell "no releases yet" from "not allowed to look".
  final String updateToken;

  /// Returns the currently active persona, falling back to a default profile.
  PersonaProfile get activePersona {
    if (personas.isNotEmpty) {
      for (final PersonaProfile p in personas) {
        if (p.id == activePersonaId) return p;
      }
      return personas.first;
    }
    return PersonaProfile(
      id: 'default',
      name: personaName.isEmpty ? 'You' : personaName,
      description: personaDescription,
    );
  }

  /// True when there is enough here to attempt a request.
  bool get isConfigured =>
      apiKey.trim().isNotEmpty &&
      baseUrl.trim().isNotEmpty &&
      model.trim().isNotEmpty;

  /// What is missing, phrased for a user rather than a log.
  String get configurationProblem {
    if (baseUrl.trim().isEmpty) return 'No base URL set.';
    if (model.trim().isEmpty) return 'No model name set.';
    if (apiKey.trim().isEmpty) return 'No API key set.';
    return '';
  }

  AppSettings copyWith({
    String? baseUrl,
    String? apiKey,
    String? model,
    double? temperature,
    int? maxTokens,
    bool clearMaxTokens = false,
    String? personaName,
    String? personaDescription,
    List<PersonaProfile>? personas,
    String? activePersonaId,
    String? authorNote,
    int? contextBudget,
    String? updateRepo,
    String? updateToken,
  }) {
    final List<PersonaProfile> effectivePersonas = personas ?? this.personas;
    final String effectiveActiveId = activePersonaId ?? this.activePersonaId;

    // Resolve name and description from the selected persona if switched
    String resolvedName = personaName ?? this.personaName;
    String resolvedDescription = personaDescription ?? this.personaDescription;

    if (activePersonaId != null && effectivePersonas.isNotEmpty) {
      final PersonaProfile? found =
          effectivePersonas.cast<PersonaProfile?>().firstWhere(
                (PersonaProfile? p) => p?.id == activePersonaId,
                orElse: () => null,
              );
      if (found != null) {
        resolvedName = found.name;
        resolvedDescription = found.description;
      }
    }

    return AppSettings(
      baseUrl: baseUrl ?? this.baseUrl,
      apiKey: apiKey ?? this.apiKey,
      model: model ?? this.model,
      temperature: temperature ?? this.temperature,
      maxTokens: clearMaxTokens ? null : (maxTokens ?? this.maxTokens),
      personaName: resolvedName,
      personaDescription: resolvedDescription,
      personas: effectivePersonas,
      activePersonaId: effectiveActiveId,
      authorNote: authorNote ?? this.authorNote,
      contextBudget: contextBudget ?? this.contextBudget,
      updateRepo: updateRepo ?? this.updateRepo,
      updateToken: updateToken ?? this.updateToken,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'baseUrl': baseUrl,
        'apiKey': apiKey,
        'model': model,
        'temperature': temperature,
        if (maxTokens != null) 'maxTokens': maxTokens,
        'personaName': personaName,
        'personaDescription': personaDescription,
        'personas': <Map<String, dynamic>>[
          for (final PersonaProfile p in personas) p.toJson(),
        ],
        'activePersonaId': activePersonaId,
        'authorNote': authorNote,
        'contextBudget': contextBudget,
        'updateRepo': updateRepo,
        'updateToken': updateToken,
      };

  factory AppSettings.fromJson(Map<String, dynamic> json) {
    final String name =
        json['personaName'] is String ? json['personaName'] as String : 'You';
    final String description = json['personaDescription'] is String
        ? json['personaDescription'] as String
        : '';

    final List<PersonaProfile> parsedPersonas = <PersonaProfile>[];
    if (json['personas'] is List) {
      for (final Object? item in json['personas'] as List) {
        if (item is Map) {
          parsedPersonas.add(
            PersonaProfile.fromJson(Map<String, dynamic>.from(item)),
          );
        }
      }
    }

    if (parsedPersonas.isEmpty) {
      parsedPersonas.add(
        PersonaProfile(
          id: 'default',
          name: name,
          description: description,
        ),
      );
    }

    final String activeId = json['activePersonaId'] is String &&
            (json['activePersonaId'] as String).isNotEmpty
        ? json['activePersonaId'] as String
        : parsedPersonas.first.id;

    return AppSettings(
      baseUrl: json['baseUrl'] is String
          ? json['baseUrl'] as String
          : 'https://api.openai.com/v1',
      apiKey: json['apiKey'] is String ? json['apiKey'] as String : '',
      model: json['model'] is String ? json['model'] as String : 'gpt-4o-mini',
      temperature: json['temperature'] is num
          ? (json['temperature'] as num).toDouble()
          : 0.9,
      maxTokens: json['maxTokens'] is int ? json['maxTokens'] as int : null,
      personaName: name,
      personaDescription: description,
      personas: parsedPersonas,
      activePersonaId: activeId,
      authorNote:
          json['authorNote'] is String ? json['authorNote'] as String : '',
      contextBudget:
          json['contextBudget'] is int ? json['contextBudget'] as int : 32768,
      updateRepo: json['updateRepo'] is String
          ? json['updateRepo'] as String
          : 'kestrelawen/decanter',
      updateToken:
          json['updateToken'] is String ? json['updateToken'] as String : '',
    );
  }
}

/// Loads and saves [AppSettings].
///
/// SECURITY: the API key is stored in `SharedPreferences`, which is plaintext
/// on disk. That is the same posture as most BYOK clients and it is the user's
/// own key on their own device, but it is not encrypted at rest. Moving to
/// `flutter_secure_storage` (Android Keystore) is the correct next step and is
/// deliberately not pretended otherwise here.
class SettingsStore {
  static const String _key = 'decanter.settings.v1';

  Future<AppSettings> load() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return const AppSettings();
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is Map) {
        return AppSettings.fromJson(Map<String, dynamic>.from(decoded));
      }
    } on FormatException {
      // Corrupt blob: better to start from defaults than refuse to launch.
    }
    return const AppSettings();
  }

  Future<void> save(AppSettings settings) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(settings.toJson()));
  }
}
