import 'package:flutter/material.dart';

import 'glass.dart';
import 'settings.dart';

/// Where the user points the app at a model.
///
/// Returns the edited settings via `Navigator.pop`, or null if cancelled.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.initial});

  final AppSettings initial;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late AppSettings _draft = widget.initial;

  late final TextEditingController _baseUrl = TextEditingController(
    text: widget.initial.baseUrl,
  );
  late final TextEditingController _apiKey = TextEditingController(
    text: widget.initial.apiKey,
  );
  late final TextEditingController _model = TextEditingController(
    text: widget.initial.model,
  );
  late final TextEditingController _persona = TextEditingController(
    text: widget.initial.personaName,
  );

  bool _revealKey = false;

  @override
  void dispose() {
    _baseUrl.dispose();
    _apiKey.dispose();
    _model.dispose();
    _persona.dispose();
    super.dispose();
  }

  void _applyPreset(BackendPreset preset) {
    setState(() {
      _baseUrl.text = preset.baseUrl;
      // Only overwrite the model if the user has not written their own — losing
      // a typed model name on a preset tap would be infuriating.
      if (_model.text.trim().isEmpty ||
          BackendPreset.all.any((BackendPreset p) => p.defaultModel == _model.text)) {
        _model.text = preset.defaultModel;
      }
      _draft = _draft.copyWith(
        baseUrl: preset.baseUrl,
        model: _model.text,
      );
    });
  }

  AppSettings _collect() => _draft.copyWith(
    baseUrl: _baseUrl.text.trim(),
    apiKey: _apiKey.text.trim(),
    model: _model.text.trim(),
    personaName: _persona.text.trim().isEmpty ? 'You' : _persona.text.trim(),
  );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color.fromRGBO(12, 9, 8, 1),
      body: LiquidBackground(
        asset: 'assets/background.png',
        child: SafeArea(
          child: Column(
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 0),
                child: GlassPanel(
                  padding: const EdgeInsets.fromLTRB(16, 14, 10, 14),
                  child: Row(
                    children: <Widget>[
                      const Expanded(
                        child: Text(
                          'CONNECTION',
                          style: TextStyle(
                            color: Glass.textPrimary,
                            fontSize: 13,
                            letterSpacing: 1.6,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      _IconAction(
                        icon: Icons.close_rounded,
                        onTap: () => Navigator.of(context).pop(),
                      ),
                    ],
                  ),
                ),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 16),
                  children: <Widget>[
                    _presets(),
                    const SizedBox(height: 12),
                    _card(
                      title: 'ENDPOINT',
                      children: <Widget>[
                        _field(
                          label: 'Base URL',
                          controller: _baseUrl,
                          hint: 'https://api.openai.com/v1',
                          keyboard: TextInputType.url,
                        ),
                        const SizedBox(height: 12),
                        _field(
                          label: 'API key',
                          controller: _apiKey,
                          hint: 'sk-…',
                          obscure: !_revealKey,
                          trailing: IconButton(
                            onPressed: () =>
                                setState(() => _revealKey = !_revealKey),
                            icon: Icon(
                              _revealKey
                                  ? Icons.visibility_off_rounded
                                  : Icons.visibility_rounded,
                              size: 18,
                              color: Glass.textFaint,
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        _field(
                          label: 'Model',
                          controller: _model,
                          hint: 'gpt-4o-mini',
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'Any OpenAI-compatible /chat/completions endpoint '
                          'works: OpenAI, OpenRouter, DeepSeek, Groq, Ollama, '
                          'LM Studio, vLLM.',
                          style: TextStyle(
                            color: Glass.textFaint,
                            fontSize: 11,
                            height: 1.4,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    _card(
                      title: 'GENERATION',
                      children: <Widget>[
                        Row(
                          children: <Widget>[
                            const Text(
                              'Temperature',
                              style: TextStyle(
                                color: Glass.textSecondary,
                                fontSize: 12.5,
                              ),
                            ),
                            const Spacer(),
                            Text(
                              _draft.temperature.toStringAsFixed(2),
                              style: const TextStyle(
                                color: Glass.textPrimary,
                                fontSize: 12.5,
                                fontFeatures: <FontFeature>[
                                  FontFeature.tabularFigures(),
                                ],
                              ),
                            ),
                          ],
                        ),
                        SliderTheme(
                          data: SliderTheme.of(context).copyWith(
                            activeTrackColor: Glass.tint(0.75),
                            inactiveTrackColor: Glass.tint(0.16),
                            thumbColor: Glass.tint(0.95),
                            overlayColor: Glass.tint(0.12),
                            trackHeight: 3,
                          ),
                          child: Slider(
                            value: _draft.temperature.clamp(0.0, 2.0),
                            max: 2,
                            divisions: 40,
                            onChanged: (double v) =>
                                setState(() => _draft = _draft.copyWith(temperature: v)),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    _card(
                      title: 'YOU',
                      children: <Widget>[
                        _field(
                          label: 'Name used for {{user}}',
                          controller: _persona,
                          hint: 'You',
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    const Text(
                      'The API key is stored unencrypted in the app\'s local '
                      'preferences. That matches most BYOK clients, but it is '
                      'not encrypted at rest — worth knowing before you paste a '
                      'key with billing attached.',
                      style: TextStyle(
                        color: Glass.textFaint,
                        fontSize: 11,
                        height: 1.45,
                      ),
                    ),
                    const SizedBox(height: 16),
                    _saveBar(),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _presets() {
    return GlassPanel(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
      tintStrength: 0.85,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Text(
            'PRESETS',
            style: TextStyle(
              color: Glass.textSecondary,
              fontSize: 10.5,
              letterSpacing: 1.4,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              for (final BackendPreset preset in BackendPreset.all)
                GestureDetector(
                  onTap: () => _applyPreset(preset),
                  child: GlassPill(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 13,
                      vertical: 8,
                    ),
                    tintStrength:
                        _baseUrl.text.trim() == preset.baseUrl ? 2.2 : 1.0,
                    child: Text(
                      preset.label,
                      style: const TextStyle(
                        color: Glass.textPrimary,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _card({required String title, required List<Widget> children}) {
    return GlassPanel(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      tintStrength: 0.85,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            title,
            style: const TextStyle(
              color: Glass.textSecondary,
              fontSize: 10.5,
              letterSpacing: 1.4,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 12),
          ...children,
        ],
      ),
    );
  }

  Widget _field({
    required String label,
    required TextEditingController controller,
    String? hint,
    bool obscure = false,
    TextInputType? keyboard,
    Widget? trailing,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          label,
          style: const TextStyle(color: Glass.textFaint, fontSize: 11),
        ),
        const SizedBox(height: 4),
        Row(
          children: <Widget>[
            Expanded(
              child: TextField(
                controller: controller,
                obscureText: obscure,
                keyboardType: keyboard,
                autocorrect: false,
                enableSuggestions: false,
                style: const TextStyle(
                  color: Glass.textPrimary,
                  fontSize: 13.5,
                ),
                cursorColor: Glass.tint(0.9),
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  hintText: hint,
                  hintStyle: const TextStyle(
                    color: Glass.textFaint,
                    fontSize: 13.5,
                  ),
                ),
              ),
            ),
            if (trailing != null) trailing,
          ],
        ),
      ],
    );
  }

  Widget _saveBar() {
    final AppSettings pending = _collect();
    final String problem = pending.configurationProblem;

    return Column(
      children: <Widget>[
        if (problem.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text(
              problem,
              style: const TextStyle(color: Glass.textFaint, fontSize: 11.5),
            ),
          ),
        GestureDetector(
          onTap: () => Navigator.of(context).pop(pending),
          child: GlassPanel(
            padding: const EdgeInsets.symmetric(vertical: 15),
            tintStrength: 2.0,
            child: const Center(
              child: Text(
                'SAVE',
                style: TextStyle(
                  color: Glass.textPrimary,
                  fontSize: 12,
                  letterSpacing: 1.8,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// A circular glass button holding a single icon.
class _IconAction extends StatelessWidget {
  const _IconAction({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: GlassPanel(
        radius: 999,
        blur: 12,
        padding: const EdgeInsets.all(9),
        tintStrength: 1.4,
        shadow: false,
        showSpecular: false,
        child: Icon(icon, size: 17, color: Glass.textPrimary),
      ),
    );
  }
}
