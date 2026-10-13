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
    this.authorNote = '',
    this.contextBudget = 4096,
  });

  final String baseUrl;
  final String apiKey;
  final String model;

  final double temperature;
  final int? maxTokens;

  final String personaName;
  final String personaDescription;

  /// Injected into the chat at depth. Empty means no note.
  final String authorNote;

  /// Token ceiling for the assembled prompt. 0 disables trimming.
  final int contextBudget;

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
    String? authorNote,
    int? contextBudget,
  }) => AppSettings(
    baseUrl: baseUrl ?? this.baseUrl,
    apiKey: apiKey ?? this.apiKey,
    model: model ?? this.model,
    temperature: temperature ?? this.temperature,
    maxTokens: clearMaxTokens ? null : (maxTokens ?? this.maxTokens),
    personaName: personaName ?? this.personaName,
    personaDescription: personaDescription ?? this.personaDescription,
    authorNote: authorNote ?? this.authorNote,
    contextBudget: contextBudget ?? this.contextBudget,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'baseUrl': baseUrl,
    'apiKey': apiKey,
    'model': model,
    'temperature': temperature,
    if (maxTokens != null) 'maxTokens': maxTokens,
    'personaName': personaName,
    'personaDescription': personaDescription,
    'authorNote': authorNote,
    'contextBudget': contextBudget,
  };

  factory AppSettings.fromJson(Map<String, dynamic> json) => AppSettings(
    baseUrl: json['baseUrl'] is String
        ? json['baseUrl'] as String
        : 'https://api.openai.com/v1',
    apiKey: json['apiKey'] is String ? json['apiKey'] as String : '',
    model: json['model'] is String ? json['model'] as String : 'gpt-4o-mini',
    temperature: json['temperature'] is num
        ? (json['temperature'] as num).toDouble()
        : 0.9,
    maxTokens: json['maxTokens'] is int ? json['maxTokens'] as int : null,
    personaName: json['personaName'] is String
        ? json['personaName'] as String
        : 'You',
    personaDescription: json['personaDescription'] is String
        ? json['personaDescription'] as String
        : '',
    authorNote: json['authorNote'] is String ? json['authorNote'] as String : '',
    contextBudget: json['contextBudget'] is int
        ? json['contextBudget'] as int
        : 4096,
  );
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
