import 'dart:convert';

/// A single prompt injection module within a SillyTavern-compatible preset.
class PresetPrompt {
  const PresetPrompt({
    this.identifier = '',
    this.name = '',
    this.content = '',
    this.role = 'system',
    this.enabled = true,
    this.systemPrompt = false,
    this.marker = false,
    this.injectionPosition = 0,
    this.injectionDepth = 0,
    this.injectionOrder = 100,
  });

  final String identifier;
  final String name;
  final String content;
  final String role;
  final bool enabled;
  final bool systemPrompt;
  final bool marker;
  final int injectionPosition;
  final int injectionDepth;
  final int injectionOrder;

  PresetPrompt copyWith({
    String? identifier,
    String? name,
    String? content,
    String? role,
    bool? enabled,
    bool? systemPrompt,
    bool? marker,
    int? injectionPosition,
    int? injectionDepth,
    int? injectionOrder,
  }) {
    return PresetPrompt(
      identifier: identifier ?? this.identifier,
      name: name ?? this.name,
      content: content ?? this.content,
      role: role ?? this.role,
      enabled: enabled ?? this.enabled,
      systemPrompt: systemPrompt ?? this.systemPrompt,
      marker: marker ?? this.marker,
      injectionPosition: injectionPosition ?? this.injectionPosition,
      injectionDepth: injectionDepth ?? this.injectionDepth,
      injectionOrder: injectionOrder ?? this.injectionOrder,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'identifier': identifier,
        'name': name,
        'content': content,
        'role': role,
        'enabled': enabled,
        'system_prompt': systemPrompt,
        'marker': marker,
        'injection_position': injectionPosition,
        'injection_depth': injectionDepth,
        'injection_order': injectionOrder,
      };

  factory PresetPrompt.fromJson(Map<String, dynamic> json) {
    return PresetPrompt(
      identifier: json['identifier'] as String? ?? '',
      name: json['name'] as String? ?? '',
      content: json['content'] as String? ?? '',
      role: json['role'] as String? ?? 'system',
      enabled: json['enabled'] as bool? ?? true,
      systemPrompt: json['system_prompt'] as bool? ?? false,
      marker: json['marker'] as bool? ?? false,
      injectionPosition: (json['injection_position'] as num?)?.toInt() ?? 0,
      injectionDepth: (json['injection_depth'] as num?)?.toInt() ?? 0,
      injectionOrder: (json['injection_order'] as num?)?.toInt() ?? 100,
    );
  }
}

/// A complete generation & sampling preset, compatible with SillyTavern JSON.
class GenerationPreset {
  const GenerationPreset({
    required this.name,
    this.description = '',
    this.temperature = 0.9,
    this.topP = 0.95,
    this.topK,
    this.frequencyPenalty = 0.0,
    this.presencePenalty = 0.0,
    this.repetitionPenalty = 1.0,
    this.minP,
    this.topA,
    this.maxTokens,
    this.maxContext,
    this.wiFormat = '{0}',
    this.scenarioFormat = '{{scenario}}',
    this.personalityFormat = '{{personality}}',
    this.impersonationPrompt,
    this.continueNudgePrompt,
    this.prompts = const <PresetPrompt>[],
  });

  final String name;
  final String description;
  final double temperature;
  final double? topP;
  final int? topK;
  final double? frequencyPenalty;
  final double? presencePenalty;
  final double? repetitionPenalty;
  final double? minP;
  final double? topA;
  final int? maxTokens;
  final int? maxContext;
  final String wiFormat;
  final String scenarioFormat;
  final String personalityFormat;
  final String? impersonationPrompt;
  final String? continueNudgePrompt;
  final List<PresetPrompt> prompts;

  /// Default balanced preset for roleplay.
  factory GenerationPreset.defaultPreset() => const GenerationPreset(
        name: 'Default',
        description: 'Balanced temperature and sampling for natural roleplay.',
        temperature: 0.9,
        topP: 0.95,
        frequencyPenalty: 0.0,
        presencePenalty: 0.0,
      );

  /// High creativity, vivid narration.
  factory GenerationPreset.creativeStoryteller() => const GenerationPreset(
        name: 'Creative Storyteller',
        description: 'Vivid imagery, rich narrative descriptions, and higher variation.',
        temperature: 1.05,
        topP: 0.95,
        frequencyPenalty: 0.15,
        presencePenalty: 0.1,
      );

  /// Low temperature for strict consistency, chain-of-thought, and precision.
  factory GenerationPreset.precise() => const GenerationPreset(
        name: 'Precise / CoT',
        description: 'Low randomness for analytical prompts and strict instruction following.',
        temperature: 0.3,
        topP: 0.85,
        frequencyPenalty: 0.0,
        presencePenalty: 0.0,
      );

  /// Deep literary prose tuned for longform outputs.
  factory GenerationPreset.novelLongform() => const GenerationPreset(
        name: 'Novel / Longform',
        description: 'Grounded literary pace with expanded output tokens.',
        temperature: 0.85,
        topP: 0.9,
        frequencyPenalty: 0.1,
        presencePenalty: 0.05,
        maxTokens: 4096,
      );

  /// All standard built-in presets shipped with Decanter.
  static List<GenerationPreset> builtIns() => <GenerationPreset>[
        GenerationPreset.defaultPreset(),
        GenerationPreset.creativeStoryteller(),
        GenerationPreset.precise(),
        GenerationPreset.novelLongform(),
      ];

  GenerationPreset copyWith({
    String? name,
    String? description,
    double? temperature,
    double? topP,
    int? topK,
    double? frequencyPenalty,
    double? presencePenalty,
    double? repetitionPenalty,
    double? minP,
    double? topA,
    int? maxTokens,
    int? maxContext,
    String? wiFormat,
    String? scenarioFormat,
    String? personalityFormat,
    String? impersonationPrompt,
    String? continueNudgePrompt,
    List<PresetPrompt>? prompts,
  }) {
    return GenerationPreset(
      name: name ?? this.name,
      description: description ?? this.description,
      temperature: temperature ?? this.temperature,
      topP: topP ?? this.topP,
      topK: topK ?? this.topK,
      frequencyPenalty: frequencyPenalty ?? this.frequencyPenalty,
      presencePenalty: presencePenalty ?? this.presencePenalty,
      repetitionPenalty: repetitionPenalty ?? this.repetitionPenalty,
      minP: minP ?? this.minP,
      topA: topA ?? this.topA,
      maxTokens: maxTokens ?? this.maxTokens,
      maxContext: maxContext ?? this.maxContext,
      wiFormat: wiFormat ?? this.wiFormat,
      scenarioFormat: scenarioFormat ?? this.scenarioFormat,
      personalityFormat: personalityFormat ?? this.personalityFormat,
      impersonationPrompt: impersonationPrompt ?? this.impersonationPrompt,
      continueNudgePrompt: continueNudgePrompt ?? this.continueNudgePrompt,
      prompts: prompts ?? this.prompts,
    );
  }

  /// Parses from standard SillyTavern JSON preset format.
  factory GenerationPreset.fromSillyTavernJson(
    Map<String, dynamic> json, {
    String? name,
  }) {
    final List<PresetPrompt> loadedPrompts = <PresetPrompt>[];
    if (json['prompts'] is List<dynamic>) {
      for (final dynamic item in json['prompts'] as List<dynamic>) {
        if (item is Map<String, dynamic>) {
          loadedPrompts.add(PresetPrompt.fromJson(item));
        }
      }
    }

    final String resolvedName = name ??
        json['name'] as String? ??
        json['preset_name'] as String? ??
        'Imported Preset';

    return GenerationPreset(
      name: resolvedName,
      description: json['description'] as String? ?? '',
      temperature: (json['temperature'] as num?)?.toDouble() ?? 0.9,
      topP: (json['top_p'] as num?)?.toDouble(),
      topK: (json['top_k'] as num?)?.toInt(),
      frequencyPenalty: (json['frequency_penalty'] as num?)?.toDouble() ?? 0.0,
      presencePenalty: (json['presence_penalty'] as num?)?.toDouble() ?? 0.0,
      repetitionPenalty: (json['repetition_penalty'] as num?)?.toDouble() ?? 1.0,
      minP: (json['min_p'] as num?)?.toDouble(),
      topA: (json['top_a'] as num?)?.toDouble(),
      maxTokens: (json['openai_max_tokens'] as num?)?.toInt() ??
          (json['max_tokens'] as num?)?.toInt(),
      maxContext: (json['openai_max_context'] as num?)?.toInt() ??
          (json['max_context'] as num?)?.toInt(),
      wiFormat: json['wi_format'] as String? ?? '{0}',
      scenarioFormat: json['scenario_format'] as String? ?? '{{scenario}}',
      personalityFormat:
          json['personality_format'] as String? ?? '{{personality}}',
      impersonationPrompt: json['impersonation_prompt'] as String?,
      continueNudgePrompt: json['continue_nudge_prompt'] as String?,
      prompts: loadedPrompts,
    );
  }

  /// Exports as standard SillyTavern JSON preset format.
  Map<String, dynamic> toSillyTavernJson() => <String, dynamic>{
        'name': name,
        'temperature': temperature,
        if (topP != null) 'top_p': topP,
        if (topK != null) 'top_k': topK,
        if (frequencyPenalty != null) 'frequency_penalty': frequencyPenalty,
        if (presencePenalty != null) 'presence_penalty': presencePenalty,
        if (repetitionPenalty != null) 'repetition_penalty': repetitionPenalty,
        if (minP != null) 'min_p': minP,
        if (topA != null) 'top_a': topA,
        if (maxTokens != null) 'openai_max_tokens': maxTokens,
        if (maxContext != null) 'openai_max_context': maxContext,
        'wi_format': wiFormat,
        'scenario_format': scenarioFormat,
        'personality_format': personalityFormat,
        if (impersonationPrompt != null)
          'impersonation_prompt': impersonationPrompt,
        if (continueNudgePrompt != null)
          'continue_nudge_prompt': continueNudgePrompt,
        if (prompts.isNotEmpty)
          'prompts': <Map<String, dynamic>>[
            for (final PresetPrompt p in prompts) p.toJson(),
          ],
      };

  String exportJson() =>
      const JsonEncoder.withIndent('  ').convert(toSillyTavernJson());
}
