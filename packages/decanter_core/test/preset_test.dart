import 'dart:convert';
import 'package:decanter_core/decanter_core.dart';
import 'package:test/test.dart';

void main() {
  group('GenerationPreset', () {
    test('builtIns contains 4 distinct presets', () {
      final List<GenerationPreset> presets = GenerationPreset.builtIns();
      expect(presets.length, 4);
      final List<String> names = presets.map((p) => p.name).toList();
      expect(names, contains('Default'));
      expect(names, contains('Creative Storyteller'));
      expect(names, contains('Precise / CoT'));
      expect(names, contains('Novel / Longform'));
    });

    test('parses SillyTavern JSON with samplers and prompts', () {
      final Map<String, dynamic> stJson = <String, dynamic>{
        'name': "Sola's Mind",
        'temperature': 0.95,
        'top_p': 0.9,
        'frequency_penalty': 0.2,
        'presence_penalty': 0.1,
        'openai_max_tokens': 4096,
        'openai_max_context': 65536,
        'wi_format': '{0}',
        'scenario_format': 'Current Scenario:\n{{scenario}}',
        'prompts': <Map<String, dynamic>>[
          <String, dynamic>{
            'identifier': 'prompt-1',
            'name': 'Writing Guidelines',
            'content': 'Write in a naturalistic voice.',
            'role': 'system',
            'enabled': true,
            'injection_position': 0,
            'injection_depth': 0,
            'injection_order': 10,
          },
          <String, dynamic>{
            'identifier': 'prompt-2',
            'name': 'Depth Injection',
            'content': 'Remember pacing.',
            'role': 'system',
            'enabled': true,
            'injection_position': 1,
            'injection_depth': 2,
            'injection_order': 20,
          },
        ],
      };

      final GenerationPreset preset =
          GenerationPreset.fromSillyTavernJson(stJson);
      expect(preset.name, "Sola's Mind");
      expect(preset.temperature, 0.95);
      expect(preset.topP, 0.9);
      expect(preset.frequencyPenalty, 0.2);
      expect(preset.presencePenalty, 0.1);
      expect(preset.maxTokens, 4096);
      expect(preset.maxContext, 65536);
      expect(preset.scenarioFormat, 'Current Scenario:\n{{scenario}}');
      expect(preset.prompts.length, 2);
      expect(preset.prompts[0].name, 'Writing Guidelines');
      expect(preset.prompts[0].enabled, isTrue);

      final Map<String, dynamic> exported = preset.toSillyTavernJson();
      expect(exported['temperature'], 0.95);
      expect(exported['openai_max_tokens'], 4096);
      expect(exported['scenario_format'], 'Current Scenario:\n{{scenario}}');
      final List<dynamic> promptsExport = exported['prompts'] as List<dynamic>;
      expect(promptsExport.length, 2);
    });
  });

  group('MacroExpander preset macros', () {
    final MacroContext ctx = const MacroContext(
      charName: 'Lyra',
      userName: 'Arthur',
    );

    test('expands comments to empty string', () {
      final MacroExpander expander = MacroExpander(context: ctx);
      final String result =
          expander.expand('Before{{// this is a hidden comment}}After');
      expect(result, 'BeforeAfter');
    });

    test('expands trim macro to empty string', () {
      final MacroExpander expander = MacroExpander(context: ctx);
      final String result = expander.expand('Hello{{trim}}World');
      expect(result, 'HelloWorld');
    });

    test('sets and gets session variables with setvar and getvar', () {
      final MacroExpander expander = MacroExpander(context: ctx);
      final String prompt =
          '{{setvar::mood::cheerful}}Lyra is in a {{getvar::mood}} mood.';
      final String result = expander.expand(prompt);
      expect(result, 'Lyra is in a cheerful mood.');
    });

    test('handles clearing variable with empty setvar', () {
      final MacroExpander expander = MacroExpander(context: ctx);
      expander.expand('{{setvar::temp::active}}');
      expect(expander.expand('Current: {{getvar::temp}}'), 'Current: active');
      expander.expand('{{setvar::temp::}}');
      expect(expander.expand('Current: {{getvar::temp}}'), 'Current: ');
    });
  });

  group('PromptAssembler with GenerationPreset', () {
    final TavernCard card = TavernCard.create(
      name: 'Lyra',
      description: 'An alchemist.',
      personality: 'Sharp-witted.',
      scenario: 'A quiet evening in the workshop.',
      firstMes: 'Welcome.',
    );

    test('injects preset custom scenario format and prompt modules', () {
      final GenerationPreset preset = GenerationPreset(
        name: 'Custom',
        scenarioFormat: 'SCENARIO SETTING:\n{{scenario}}',
        prompts: const <PresetPrompt>[
          PresetPrompt(
            identifier: 'rule-1',
            name: 'Pacing Rule',
            content: 'Maintain slow, descriptive pacing.',
            role: 'system',
            enabled: true,
            injectionPosition: 0,
            injectionOrder: 5,
          ),
          PresetPrompt(
            identifier: 'disabled-rule',
            name: 'Ignored',
            content: 'Should not appear.',
            role: 'system',
            enabled: false,
          ),
        ],
      );

      final AssembledPrompt assembled = const PromptAssembler().assemble(
        card: card,
        userName: 'Arthur',
        preset: preset,
      );

      final String fullSystem = assembled.messages
          .where((m) => m.role == ChatRole.system)
          .map((m) => m.content)
          .join('\n');

      expect(fullSystem, contains('SCENARIO SETTING:'));
      expect(fullSystem, contains('A quiet evening in the workshop.'));
      expect(fullSystem, contains('Maintain slow, descriptive pacing.'));
      expect(fullSystem, isNot(contains('Should not appear.')));
    });
  });
}
