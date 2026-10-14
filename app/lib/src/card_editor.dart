import 'package:decanter_core/decanter_core.dart';
import 'package:flutter/material.dart';

import 'glass.dart';

/// Glass sheet dialog for creating a new character card or editing an existing one.
class CardEditorSheet extends StatefulWidget {
  const CardEditorSheet({
    super.key,
    this.initialCard,
    this.entryId,
    required this.store,
    required this.onSaved,
  });

  final TavernCard? initialCard;
  final String? entryId;
  final LibraryStore store;
  final ValueChanged<TavernCard> onSaved;

  static Future<TavernCard?> show({
    required BuildContext context,
    TavernCard? card,
    String? entryId,
    required LibraryStore store,
  }) {
    return showModalBottomSheet<TavernCard>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (BuildContext sheetContext) {
        return CardEditorSheet(
          initialCard: card,
          entryId: entryId,
          store: store,
          onSaved: (TavernCard saved) => Navigator.of(sheetContext).pop(saved),
        );
      },
    );
  }

  @override
  State<CardEditorSheet> createState() => _CardEditorSheetState();
}

class _CardEditorSheetState extends State<CardEditorSheet> {
  late final TextEditingController _name;
  late final TextEditingController _creator;
  late final TextEditingController _version;
  late final TextEditingController _description;
  late final TextEditingController _personality;
  late final TextEditingController _scenario;
  late final TextEditingController _firstMes;
  late final TextEditingController _creatorNotes;
  late final TextEditingController _systemPrompt;
  late final List<TextEditingController> _altGreetingControllers;

  bool _saving = false;
  String? _error;

  bool get _isEditing => widget.initialCard != null;

  @override
  void initState() {
    super.initState();
    final TavernCard? card = widget.initialCard;
    _name = TextEditingController(text: card?.name ?? '');
    _creator = TextEditingController(text: card?.creator ?? '');
    _version = TextEditingController(text: card?.characterVersion ?? '1.0');
    _description = TextEditingController(text: card?.description ?? '');
    _personality = TextEditingController(text: card?.personality ?? '');
    _scenario = TextEditingController(text: card?.scenario ?? '');
    _firstMes = TextEditingController(text: card?.firstMes ?? '');
    _creatorNotes = TextEditingController(text: card?.creatorNotes ?? '');
    _systemPrompt = TextEditingController(text: card?.systemPrompt ?? '');
    _altGreetingControllers = (card?.alternateGreetings ?? <String>[])
        .map((String g) => TextEditingController(text: g))
        .toList();
  }

  @override
  void dispose() {
    _name.dispose();
    _creator.dispose();
    _version.dispose();
    _description.dispose();
    _personality.dispose();
    _scenario.dispose();
    _firstMes.dispose();
    _creatorNotes.dispose();
    _systemPrompt.dispose();
    for (final TextEditingController c in _altGreetingControllers) {
      c.dispose();
    }
    super.dispose();
  }

  void _addGreeting() {
    setState(() {
      _altGreetingControllers.add(TextEditingController());
    });
  }

  void _removeGreeting(int index) {
    setState(() {
      final TextEditingController c = _altGreetingControllers.removeAt(index);
      c.dispose();
    });
  }

  void _save() {
    final String name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Please enter a character name.');
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });

    final List<String> alternateGreetings = _altGreetingControllers
        .map((TextEditingController c) => c.text.trim())
        .where((String s) => s.isNotEmpty)
        .toList();

    try {
      final TavernCard updated;
      if (_isEditing) {
        updated = widget.initialCard!.copyWith(
          name: name,
          creator: _creator.text.trim(),
          characterVersion: _version.text.trim(),
          description: _description.text.trim(),
          personality: _personality.text.trim(),
          scenario: _scenario.text.trim(),
          firstMes: _firstMes.text.trim(),
          alternateGreetings: alternateGreetings,
          creatorNotes: _creatorNotes.text.trim(),
          systemPrompt: _systemPrompt.text.trim(),
        );
        if (widget.entryId != null) {
          widget.store.saveCard(widget.entryId!, updated);
        }
      } else {
        updated = TavernCard.create(
          name: name,
          creator: _creator.text.trim(),
          characterVersion: _version.text.trim(),
          description: _description.text.trim(),
          personality: _personality.text.trim(),
          scenario: _scenario.text.trim(),
          firstMes: _firstMes.text.trim(),
          alternateGreetings: alternateGreetings,
          creatorNotes: _creatorNotes.text.trim(),
          systemPrompt: _systemPrompt.text.trim(),
        );
        widget.store.createCard(updated);
      }

      widget.onSaved(updated);
    } catch (e) {
      setState(() {
        _saving = false;
        _error = 'Failed to save card: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final double keyboardOffset = MediaQuery.of(context).viewInsets.bottom;

    return Padding(
      padding: EdgeInsets.fromLTRB(12, 40, 12, 16 + keyboardOffset),
      child: GlassPanel(
        radius: 28,
        blur: 36,
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 18),
        tintStrength: 1.45,
        child: Column(
          mainAxisSize: MainAxisSize.min,
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
            const SizedBox(height: 12),
            Row(
              children: <Widget>[
                Icon(
                  _isEditing ? Icons.edit_note_rounded : Icons.person_add_rounded,
                  size: 20,
                  color: Glass.textSecondary,
                ),
                const SizedBox(width: 8),
                Text(
                  _isEditing ? 'EDIT CHARACTER' : 'CREATE CHARACTER',
                  style: const TextStyle(
                    color: Glass.textPrimary,
                    fontSize: 12.5,
                    letterSpacing: 1.4,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                GestureDetector(
                  onTap: _saving ? null : _save,
                  child: GlassPill(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 6,
                    ),
                    tintStrength: _saving ? 0.8 : 1.8,
                    child: _saving
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text(
                            'SAVE',
                            style: TextStyle(
                              color: Glass.textPrimary,
                              fontSize: 11,
                              letterSpacing: 1.2,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (_error != null) ...<Widget>[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color.fromRGBO(180, 50, 50, 0.25),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: const Color.fromRGBO(240, 100, 100, 0.4),
                  ),
                ),
                child: Text(
                  _error!,
                  style: const TextStyle(
                    color: Color.fromRGBO(255, 180, 180, 1),
                    fontSize: 12,
                  ),
                ),
              ),
              const SizedBox(height: 10),
            ],
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    _field(
                      label: 'Character Name',
                      controller: _name,
                      hint: 'e.g. Alice, The Dorm',
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: <Widget>[
                        Expanded(
                          child: _field(
                            label: 'Creator / Author',
                            controller: _creator,
                            hint: 'e.g. Anonymous',
                          ),
                        ),
                        const SizedBox(width: 10),
                        SizedBox(
                          width: 80,
                          child: _field(
                            label: 'Version',
                            controller: _version,
                            hint: '1.0',
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    _field(
                      label: 'Description / Summary',
                      controller: _description,
                      hint: 'Physical appearance, traits, background...',
                      maxLines: 4,
                    ),
                    const SizedBox(height: 10),
                    _field(
                      label: 'Personality',
                      controller: _personality,
                      hint: 'Behavior, tone, mannerisms, speaking style...',
                      maxLines: 3,
                    ),
                    const SizedBox(height: 10),
                    _field(
                      label: 'Scenario',
                      controller: _scenario,
                      hint: 'Circumstances and setting of the roleplay...',
                      maxLines: 3,
                    ),
                    const SizedBox(height: 10),
                    _field(
                      label: 'First Message (Greeting)',
                      controller: _firstMes,
                      hint: 'Opening narrative turn sent when starting chat...',
                      maxLines: 4,
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: <Widget>[
                        const Text(
                          'ALTERNATE GREETINGS',
                          style: TextStyle(
                            color: Glass.textFaint,
                            fontSize: 10,
                            letterSpacing: 1.2,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const Spacer(),
                        GestureDetector(
                          onTap: _addGreeting,
                          child: const Padding(
                            padding: EdgeInsets.symmetric(vertical: 4),
                            child: Row(
                              children: <Widget>[
                                Icon(Icons.add_rounded,
                                    size: 14, color: Glass.textSecondary),
                                SizedBox(width: 4),
                                Text(
                                  'ADD GREETING',
                                  style: TextStyle(
                                    color: Glass.textSecondary,
                                    fontSize: 10,
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: 1,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    if (_altGreetingControllers.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 4),
                        child: Text(
                          'No alternate greetings. Tap ADD GREETING to add more opening options.',
                          style: TextStyle(
                            color: Glass.textFaint,
                            fontSize: 11,
                            fontStyle: FontStyle.italic,
                          ),
                        ),
                      )
                    else
                      for (var i = 0; i < _altGreetingControllers.length; i++) ...<Widget>[
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Expanded(
                                child: _field(
                                  label: 'Greeting ${i + 2}',
                                  controller: _altGreetingControllers[i],
                                  hint: 'Alternate opening...',
                                  maxLines: 3,
                                ),
                              ),
                              const SizedBox(width: 6),
                              Padding(
                                padding: const EdgeInsets.only(top: 24),
                                child: GestureDetector(
                                  onTap: () => _removeGreeting(i),
                                  child: Container(
                                    padding: const EdgeInsets.all(6),
                                    decoration: BoxDecoration(
                                      color: Glass.shade(0.3),
                                      shape: BoxShape.circle,
                                    ),
                                    child: const Icon(
                                      Icons.close_rounded,
                                      size: 14,
                                      color: Glass.textFaint,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    const SizedBox(height: 10),
                    _field(
                      label: 'Creator Notes / Prompt Directives',
                      controller: _creatorNotes,
                      hint: 'Invisible author steering notes, scene rules...',
                      maxLines: 3,
                    ),
                    const SizedBox(height: 10),
                    _field(
                      label: 'System Prompt Override',
                      controller: _systemPrompt,
                      hint: 'Optional override for character system instructions...',
                      maxLines: 3,
                    ),
                    const SizedBox(height: 10),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _field({
    required String label,
    required TextEditingController controller,
    String? hint,
    int maxLines = 1,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          label,
          style: const TextStyle(
            color: Glass.textSecondary,
            fontSize: 11.5,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 5),
        Container(
          decoration: BoxDecoration(
            color: Glass.shade(0.35),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: Glass.tint(0.15),
              width: 0.8,
            ),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: TextField(
            controller: controller,
            maxLines: maxLines,
            style: const TextStyle(
              color: Glass.textPrimary,
              fontSize: 13,
            ),
            decoration: InputDecoration(
              isDense: true,
              border: InputBorder.none,
              contentPadding: EdgeInsets.zero,
              hintText: hint,
              hintStyle: const TextStyle(
                color: Glass.textFaint,
                fontSize: 12,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
