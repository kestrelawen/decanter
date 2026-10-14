import 'package:decanter_core/decanter_core.dart';
import 'package:flutter/material.dart';

import 'glass.dart';
import 'settings.dart';
import 'update_screen.dart';
import 'update_service.dart';

/// Where the user points the app at a model.
///
/// Returns the edited settings via `Navigator.pop`, or null if cancelled.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.initial,
    this.transportFactory,
  });

  final AppSettings initial;

  /// How to reach the endpoint when fetching the model list.
  ///
  /// Injectable so that button can be tested without a network, the same seam
  /// the chat controller uses for its backend.
  final HttpTransport Function()? transportFactory;

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
  late final TextEditingController _updateRepo = TextEditingController(
    text: widget.initial.updateRepo,
  );
  late final TextEditingController _updateToken = TextEditingController(
    text: widget.initial.updateToken,
  );

  bool _revealKey = false;
  bool _fetchingModels = false;
  String? _modelError;

  @override
  void dispose() {
    _baseUrl.dispose();
    _apiKey.dispose();
    _model.dispose();
    _persona.dispose();
    _updateRepo.dispose();
    _updateToken.dispose();
    super.dispose();
  }

  void _applyPreset(BackendPreset preset) {
    setState(() {
      _baseUrl.text = preset.baseUrl;
      // Only overwrite the model if the user has not written their own — losing
      // a typed model name on a preset tap would be infuriating.
      if (_model.text.trim().isEmpty ||
          BackendPreset.all
              .any((BackendPreset p) => p.defaultModel == _model.text)) {
        _model.text = preset.defaultModel;
      }
      _draft = _draft.copyWith(
        baseUrl: preset.baseUrl,
        model: _model.text,
      );
    });
  }

  Widget _fetchModelsButton() {
    return GestureDetector(
      onTap: _fetchingModels ? null : _fetchModels,
      child: GlassPill(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
        tintStrength: _fetchingModels ? 0.9 : 1.6,
        child: _fetchingModels
            ? const SizedBox(
                height: 12,
                width: 12,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Text(
                'FETCH',
                style: TextStyle(
                  color: Glass.textPrimary,
                  fontSize: 10,
                  letterSpacing: 1.2,
                  fontWeight: FontWeight.w600,
                ),
              ),
      ),
    );
  }

  /// Asks the endpoint which models it serves, and offers them.
  ///
  /// Worth the round trip: the model name is the field people get wrong, and
  /// every OpenAI-compatible server can answer this one.
  Future<void> _fetchModels() async {
    if (_fetchingModels) return;

    final AppSettings draft = _collect();
    if (draft.baseUrl.trim().isEmpty) {
      setState(() => _modelError = 'Set a base URL first.');
      return;
    }

    setState(() {
      _fetchingModels = true;
      _modelError = null;
    });

    final OpenAiCompatibleBackend backend = OpenAiCompatibleBackend(
      baseUrl: draft.baseUrl,
      apiKey: draft.apiKey,
      transport: widget.transportFactory?.call() ?? IoHttpTransport(),
    );

    var failure = '';
    var models = const <String>[];
    var contextLengths = const <String, int>{};
    try {
      final catalog = await backend.fetchCatalog();
      models = catalog.models;
      contextLengths = catalog.contextLengths;
    } on BackendException catch (error) {
      failure = error.friendlyMessage;
    } on Object catch (error) {
      failure = 'Could not reach that endpoint: $error';
    } finally {
      await backend.close();
    }

    if (!mounted) return;
    setState(() => _fetchingModels = false);

    if (failure.isNotEmpty) {
      setState(() => _modelError = failure);
      return;
    }

    if (models.isEmpty) {
      // Not every server implements /models, and that is no reason to make the
      // field look broken.
      setState(
        () => _modelError =
            'That endpoint listed no models. Some servers do not implement '
                '/models — type the name in instead.',
      );
      return;
    }

    final String? chosen =
        await _pickModel(models, contextLengths: contextLengths);
    if (chosen == null || !mounted) return;
    final int? detectedBudget = contextLengths[chosen];
    setState(() {
      _model.text = chosen;
      _draft = _draft.copyWith(
        model: chosen,
        contextBudget: (detectedBudget != null && detectedBudget > 0)
            ? detectedBudget
            : _draft.contextBudget,
      );
      _modelError = null;
    });
  }

  /// Offers the fetched models and returns the chosen one, or null if dismissed.
  Future<String?> _pickModel(
    List<String> models, {
    Map<String, int> contextLengths = const <String, int>{},
  }) {
    return showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (BuildContext sheetContext) {
        String searchQuery = '';
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setModalState) {
            final List<String> filtered = models.where((String m) {
              if (searchQuery.isEmpty) return true;
              return m.toLowerCase().contains(searchQuery.toLowerCase());
            }).toList();

            return Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 16),
              child: GlassPanel(
                radius: 28,
                blur: 32,
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 18),
                tintStrength: 1.45,
                child: SizedBox(
                  height: MediaQuery.of(context).size.height * 0.75,
                  child: Column(
                    children: <Widget>[
                      Center(
                        child: Container(
                          width: 38,
                          height: 4,
                          decoration: BoxDecoration(
                            color: Glass.tint(0.35),
                            borderRadius: BorderRadius.circular(99),
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                      Row(
                        children: <Widget>[
                          const Text(
                            'MODELS',
                            style: TextStyle(
                              color: Glass.textSecondary,
                              fontSize: 11,
                              letterSpacing: 1.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const Spacer(),
                          Text(
                            searchQuery.isEmpty
                                ? '${models.length} models'
                                : '${filtered.length} of ${models.length}',
                            style: const TextStyle(
                              color: Glass.textFaint,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        decoration: BoxDecoration(
                          color: Glass.tint(0.10),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: Glass.tint(0.18)),
                        ),
                        child: Row(
                          children: <Widget>[
                            const Icon(Icons.search_rounded,
                                size: 16, color: Glass.textFaint),
                            const SizedBox(width: 8),
                            Expanded(
                              child: TextField(
                                autofocus: true,
                                onChanged: (String val) => setModalState(
                                    () => searchQuery = val.trim()),
                                style: const TextStyle(
                                  color: Glass.textPrimary,
                                  fontSize: 13,
                                ),
                                decoration: const InputDecoration(
                                  hintText: 'Search models...',
                                  hintStyle: TextStyle(
                                    color: Glass.textFaint,
                                    fontSize: 12,
                                  ),
                                  border: InputBorder.none,
                                  isDense: true,
                                  contentPadding:
                                      EdgeInsets.symmetric(vertical: 8),
                                ),
                              ),
                            ),
                            if (searchQuery.isNotEmpty)
                              GestureDetector(
                                onTap: () =>
                                    setModalState(() => searchQuery = ''),
                                child: const Icon(Icons.close_rounded,
                                    size: 16, color: Glass.textFaint),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 10),
                      Expanded(
                        child: filtered.isEmpty
                            ? Center(
                                child: Text(
                                  'No models match "$searchQuery"',
                                  style: const TextStyle(
                                    color: Glass.textFaint,
                                    fontSize: 12,
                                  ),
                                ),
                              )
                            : ScrollConfiguration(
                                behavior: const ScrollBehavior()
                                    .copyWith(overscroll: false),
                                child: ListView.builder(
                                  physics: const ClampingScrollPhysics(),
                                  itemCount: filtered.length,
                                  itemBuilder:
                                      (BuildContext context, int index) {
                                    final String modelId = filtered[index];
                                    final int? ctx = contextLengths[modelId];
                                    return ListTile(
                                      dense: true,
                                      title: Text(
                                        modelId,
                                        style: const TextStyle(
                                          color: Glass.textPrimary,
                                          fontSize: 13.5,
                                        ),
                                      ),
                                      trailing: ctx != null && ctx > 0
                                          ? Text(
                                              '${ctx ~/ 1024}k context',
                                              style: const TextStyle(
                                                color: Glass.textFaint,
                                                fontSize: 11,
                                              ),
                                            )
                                          : null,
                                      onTap: () => Navigator.of(sheetContext)
                                          .pop(modelId),
                                    );
                                  },
                                ),
                              ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _openUpdates() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => UpdateScreen(settings: _collect()),
      ),
    );
  }

  AppSettings _collect() {
    final PersonaProfile active = _draft.activePersona;
    return _draft.copyWith(
      baseUrl: _baseUrl.text.trim(),
      apiKey: _apiKey.text.trim(),
      model: _model.text.trim(),
      personaName: active.name,
      personaDescription: active.description,
      updateRepo: _updateRepo.text.trim().isEmpty
          ? 'kestrelawen/decanter'
          : _updateRepo.text.trim(),
      updateToken: _updateToken.text.trim(),
    );
  }

  Future<void> _showPersonaDialog({PersonaProfile? existing}) async {
    final TextEditingController nameCtrl =
        TextEditingController(text: existing?.name ?? '');
    final TextEditingController descCtrl =
        TextEditingController(text: existing?.description ?? '');

    final bool? saved = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        backgroundColor: const Color.fromRGBO(24, 18, 15, 0.98),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(22),
          side: BorderSide(color: Glass.tint(0.2)),
        ),
        title: Text(
          existing == null ? 'New Persona' : 'Edit Persona',
          style: const TextStyle(
            color: Glass.textPrimary,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text(
              'NAME (replaces {{user}})',
              style: TextStyle(
                color: Glass.textSecondary,
                fontSize: 10,
                letterSpacing: 1.2,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: Glass.tint(0.08),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Glass.tint(0.18)),
              ),
              child: TextField(
                controller: nameCtrl,
                style:
                    const TextStyle(color: Glass.textPrimary, fontSize: 13.5),
                decoration: const InputDecoration(
                  hintText: 'e.g. You, Kestrel, Detective',
                  hintStyle: TextStyle(color: Glass.textFaint, fontSize: 12),
                  border: InputBorder.none,
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(vertical: 10),
                ),
              ),
            ),
            const SizedBox(height: 14),
            const Text(
              'BIO / DESCRIPTION (replaces {{persona}})',
              style: TextStyle(
                color: Glass.textSecondary,
                fontSize: 10,
                letterSpacing: 1.2,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: Glass.tint(0.08),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Glass.tint(0.18)),
              ),
              child: TextField(
                controller: descCtrl,
                maxLines: 3,
                style: const TextStyle(color: Glass.textPrimary, fontSize: 13),
                decoration: const InputDecoration(
                  hintText: 'Personality, background, appearance...',
                  hintStyle: TextStyle(color: Glass.textFaint, fontSize: 12),
                  border: InputBorder.none,
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(vertical: 8),
                ),
              ),
            ),
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child:
                const Text('Cancel', style: TextStyle(color: Glass.textFaint)),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child:
                const Text('Save', style: TextStyle(color: Glass.textPrimary)),
          ),
        ],
      ),
    );

    if (saved != true) return;
    final String newName =
        nameCtrl.text.trim().isEmpty ? 'You' : nameCtrl.text.trim();
    final String newDesc = descCtrl.text.trim();

    setState(() {
      final List<PersonaProfile> current =
          List<PersonaProfile>.from(_draft.personas);
      if (existing == null) {
        final PersonaProfile created = PersonaProfile(
          id: 'p_${DateTime.now().millisecondsSinceEpoch}',
          name: newName,
          description: newDesc,
        );
        current.add(created);
        _draft = _draft.copyWith(
          personas: current,
          activePersonaId: created.id,
        );
      } else {
        final int idx =
            current.indexWhere((PersonaProfile p) => p.id == existing.id);
        if (idx != -1) {
          current[idx] = existing.copyWith(name: newName, description: newDesc);
          _draft = _draft.copyWith(personas: current);
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color.fromRGBO(12, 9, 8, 1),
      body: LiquidBackground(
        image: const AssetImage('assets/background.png'),
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
                          trailing: _fetchModelsButton(),
                        ),
                        if (_modelError != null) ...<Widget>[
                          const SizedBox(height: 6),
                          Text(
                            _modelError!,
                            style: const TextStyle(
                              color: Glass.textFaint,
                              fontSize: 11.5,
                              height: 1.4,
                            ),
                          ),
                        ],
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
                            onChanged: (double v) => setState(
                                () => _draft = _draft.copyWith(temperature: v)),
                          ),
                        ),
                        const SizedBox(height: 14),
                        Row(
                          children: <Widget>[
                            const Text(
                              'Context Budget',
                              style: TextStyle(
                                color: Glass.textSecondary,
                                fontSize: 12.5,
                              ),
                            ),
                            const Spacer(),
                            Text(
                              _draft.contextBudget > 0
                                  ? '${_draft.contextBudget ~/ 1024}k tokens'
                                  : 'Unlimited',
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
                        const SizedBox(height: 4),
                        const Text(
                          'Maximum context tokens sent to model. 0 retains full history without trimming.',
                          style: TextStyle(
                            color: Glass.textFaint,
                            fontSize: 11,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: <int>[
                            8192,
                            16384,
                            32768,
                            65536,
                            131072,
                            0,
                          ].map((int b) {
                            final bool selected = _draft.contextBudget == b;
                            final String label =
                                b == 0 ? 'Unlimited' : '${b ~/ 1024}k';
                            return GestureDetector(
                              onTap: () => setState(() =>
                                  _draft = _draft.copyWith(contextBudget: b)),
                              child: GlassPill(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 5,
                                ),
                                tintStrength: selected ? 1.6 : 0.8,
                                child: Text(
                                  label,
                                  style: TextStyle(
                                    color: selected
                                        ? Glass.textPrimary
                                        : Glass.textSecondary,
                                    fontSize: 11,
                                    fontWeight: selected
                                        ? FontWeight.w700
                                        : FontWeight.w500,
                                  ),
                                ),
                              ),
                            );
                          }).toList(),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    _card(
                      title: 'PERSONAS',
                      children: <Widget>[
                        Row(
                          children: <Widget>[
                            const Expanded(
                              child: Text(
                                'Your character personas in chats.',
                                style: TextStyle(
                                  color: Glass.textFaint,
                                  fontSize: 11,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            GestureDetector(
                              onTap: () => _showPersonaDialog(),
                              child: const GlassPill(
                                padding: EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 6,
                                ),
                                tintStrength: 1.5,
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: <Widget>[
                                    Icon(Icons.add_rounded,
                                        size: 14, color: Glass.textPrimary),
                                    SizedBox(width: 4),
                                    Text(
                                      'ADD',
                                      style: TextStyle(
                                        color: Glass.textPrimary,
                                        fontSize: 10.5,
                                        fontWeight: FontWeight.w700,
                                        letterSpacing: 0.8,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        for (final PersonaProfile p
                            in _draft.personas) ...<Widget>[
                          _personaSettingsRow(p,
                              isSelected: p.id == _draft.activePersonaId),
                          const SizedBox(height: 8),
                        ],
                      ],
                    ),
                    const SizedBox(height: 12),
                    _card(
                      title: 'UPDATES',
                      children: <Widget>[
                        Row(
                          children: <Widget>[
                            const Text(
                              'Decanter $appVersion',
                              style: TextStyle(
                                color: Glass.textPrimary,
                                fontSize: 13.5,
                              ),
                            ),
                            const Spacer(),
                            GestureDetector(
                              onTap: _openUpdates,
                              child: const GlassPill(
                                padding: EdgeInsets.symmetric(
                                  horizontal: 13,
                                  vertical: 8,
                                ),
                                tintStrength: 1.6,
                                child: Text(
                                  'CHECK',
                                  style: TextStyle(
                                    color: Glass.textPrimary,
                                    fontSize: 11,
                                    letterSpacing: 1.2,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 14),
                        _field(
                          label: 'GitHub repository',
                          controller: _updateRepo,
                          hint: 'owner/name',
                        ),
                        const SizedBox(height: 12),
                        _field(
                          label: 'GitHub token — only needed while the repo is '
                              'private',
                          controller: _updateToken,
                          hint: 'optional',
                          obscure: true,
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
          child: const GlassPanel(
            padding: EdgeInsets.symmetric(vertical: 15),
            tintStrength: 2.0,
            child: Center(
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

  Widget _personaSettingsRow(PersonaProfile p, {required bool isSelected}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: isSelected ? Glass.tint(0.18) : Glass.tint(0.06),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isSelected
              ? const Color.fromRGBO(245, 180, 80, 0.7)
              : Glass.tint(0.12),
        ),
      ),
      child: Row(
        children: <Widget>[
          GestureDetector(
            onTap: () =>
                setState(() => _draft = _draft.copyWith(activePersonaId: p.id)),
            behavior: HitTestBehavior.opaque,
            child: Icon(
              isSelected
                  ? Icons.radio_button_checked_rounded
                  : Icons.radio_button_off_rounded,
              size: 20,
              color: isSelected
                  ? const Color.fromRGBO(245, 180, 80, 1)
                  : Glass.textFaint,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: GestureDetector(
              onTap: () => setState(
                  () => _draft = _draft.copyWith(activePersonaId: p.id)),
              behavior: HitTestBehavior.opaque,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Text(
                        p.name,
                        style: const TextStyle(
                          color: Glass.textPrimary,
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (isSelected) ...<Widget>[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 5, vertical: 1),
                          decoration: BoxDecoration(
                            color: const Color.fromRGBO(245, 180, 80, 0.25),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: const Text(
                            'ACTIVE',
                            style: TextStyle(
                              color: Color.fromRGBO(245, 180, 80, 1),
                              fontSize: 8.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  if (p.description.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 2),
                    Text(
                      p.description,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Glass.textFaint,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.edit_outlined,
                size: 16, color: Glass.textSecondary),
            onPressed: () => _showPersonaDialog(existing: p),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
          ),
          if (_draft.personas.length > 1)
            IconButton(
              icon: const Icon(Icons.delete_outline_rounded,
                  size: 16, color: Color.fromRGBO(240, 100, 100, 0.8)),
              onPressed: () {
                setState(() {
                  final List<PersonaProfile> next =
                      List<PersonaProfile>.from(_draft.personas)
                        ..removeWhere((PersonaProfile item) => item.id == p.id);
                  String nextActive = _draft.activePersonaId;
                  if (nextActive == p.id) {
                    nextActive = next.first.id;
                  }
                  _draft = _draft.copyWith(
                      personas: next, activePersonaId: nextActive);
                });
              },
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
            ),
        ],
      ),
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
