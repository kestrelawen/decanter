import 'character_card.dart';
import 'chat.dart';
import 'macros.dart';
import 'tokenizer.dart';
import 'world_info.dart';
import 'world_info_engine.dart';

/// One named piece of the assembled prompt.
///
/// Kept as a list so a UI can show *why* the model saw what it saw. Prompt
/// inspectors are the difference between "the character is behaving oddly" and
/// "the lorebook injected 900 tokens above the description".
class PromptBlock {
  const PromptBlock({
    required this.id,
    required this.role,
    required this.content,
    this.source = PromptBlockSource.builtin,
    this.tokenCost = 0,
  });

  /// Stable identifier: `main`, `charDescription`, `worldInfoBefore`, ...
  final String id;
  final ChatRole role;
  final String content;
  final PromptBlockSource source;
  final int tokenCost;

  String get debugSummary => '$id (${role.name}, $tokenCost tokens)';

  @override
  String toString() => 'PromptBlock($debugSummary)';
}

enum PromptBlockSource {
  /// Derived from the character card or persona.
  card,

  /// The assembled system prompt / templates.
  builtin,

  /// Injected by World Info activation.
  lore,

  /// A user-authored note.
  user,
}

/// The system-prompt text this app ships with.
class PromptTemplates {
  const PromptTemplates({this.mainPrompt = defaultMainPrompt});

  /// SillyTavern's own default main prompt. Starting from the same line means a
  /// user's expectations carry over, and it is a deliberately minimal baseline
  /// that a real preset is meant to replace.
  static const String defaultMainPrompt =
      "Write {{char}}'s next reply in a fictional chat between "
      '{{char}} and {{user}}.';

  final String mainPrompt;
}

/// The finished prompt.
class AssembledPrompt {
  const AssembledPrompt({
    required this.messages,
    required this.blocks,
    required this.tokenCost,
    required this.droppedForBudget,
    required this.outlets,
  });

  /// What the backend should be sent, oldest first.
  final List<ChatMessage> messages;

  /// The named pieces in assembly order, including the ones injected into
  /// history, so an inspector can show everything that reached the model.
  final List<PromptBlock> blocks;

  final int tokenCost;

  /// History messages removed to fit the context budget, oldest first.
  final List<ChatMessage> droppedForBudget;

  /// Entries parked in named outlets, keyed by outlet name. Not injected on
  /// their own — reachable only through an `{{outlet::Name}}` macro.
  final Map<String, String> outlets;

  bool get isEmpty => messages.isEmpty;

  String get debugSummary =>
      '${messages.length} messages, $tokenCost tokens, ${blocks.length} blocks'
      '${droppedForBudget.isEmpty ? '' : ', ${droppedForBudget.length} dropped'}';
}

/// Builds the message list a backend receives.
///
/// Block order follows SillyTavern's assembled system prompt, which is fixed
/// and load-bearing — putting lore after the character description instead of
/// before changes how strongly the model weights it:
///
///     worldInfoBefore -> main -> worldInfoAfter -> charDescription
///     -> charPersonality -> scenario -> personaDescription
///     -> example messages -> chat history -> post-history instructions
///
/// Author's Note and depth-lore are injected *into* the history at a distance
/// from the end, as SillyTavern does, rather than appended.
class PromptAssembler {
  const PromptAssembler({this.tokenizer = const HeuristicTokenizer()});

  final Tokenizer tokenizer;

  AssembledPrompt assemble({
    required TavernCard card,
    String userName = 'User',
    String personaDescription = '',
    List<ChatMessage> history = const <ChatMessage>[],
    WorldInfoScanResult? lore,
    PromptTemplates templates = const PromptTemplates(),
    String? authorNote,
    int authorNoteDepth = 4,
    ChatRole authorNoteRole = ChatRole.system,
    int contextBudget = 0,
  }) {
    // Outlets resolve before anything expands, so a block can reference them
    // with {{outlet::Name}}.
    final outlets = _collectOutlets(lore);

    final expander = MacroExpander(
      context: MacroContext(
        charName: card.name,
        userName: userName,
        card: card,
        personaDescription: personaDescription,
        original: templates.mainPrompt,
        extra: <String, String>{
          for (final entry in outlets.entries)
            'outlet::${entry.key}': entry.value,
        },
      ),
    );

    final allBlocks = <PromptBlock>[];
    final systemBlocks = <PromptBlock>[];

    /// Expands and records a block, or returns null when it is empty.
    PromptBlock? make(String id, String content, PromptBlockSource source) {
      final trimmed = content.trim();
      if (trimmed.isEmpty) return null;
      final expanded = expander.expand(trimmed);
      final block = PromptBlock(
        id: id,
        role: ChatRole.system,
        content: expanded,
        source: source,
        tokenCost: tokenizer.count(expanded),
      );
      allBlocks.add(block);
      return block;
    }

    void addSystem(String id, String content, PromptBlockSource source) {
      final block = make(id, content, source);
      if (block != null) systemBlocks.add(block);
    }

    // --- system area, in SillyTavern's order ------------------------------
    addSystem(
      'worldInfoBefore',
      _join(lore?.at(WorldInfoPosition.beforeChar)),
      PromptBlockSource.lore,
    );

    // A character's own system prompt overrides the app default.
    addSystem(
      'main',
      card.systemPrompt.isNotEmpty ? card.systemPrompt : templates.mainPrompt,
      PromptBlockSource.builtin,
    );

    addSystem(
      'worldInfoAfter',
      _join(lore?.at(WorldInfoPosition.afterChar)),
      PromptBlockSource.lore,
    );
    addSystem('charDescription', card.description, PromptBlockSource.card);
    addSystem('charPersonality', card.personality, PromptBlockSource.card);
    addSystem('scenario', card.scenario, PromptBlockSource.card);
    addSystem('personaDescription', personaDescription, PromptBlockSource.card);

    // Example dialogue, wrapped by EM Top/Bottom lore.
    addSystem(
      'dialogueExamples',
      _joinParts(<String>[
        _join(lore?.at(WorldInfoPosition.emTop)),
        card.mesExample,
        _join(lore?.at(WorldInfoPosition.emBottom)),
      ]),
      PromptBlockSource.card,
    );

    // Post-history instructions are built now but placed last, after the chat.
    final postHistory = make(
      'postHistoryInstructions',
      card.postHistoryInstructions,
      PromptBlockSource.card,
    );

    // --- content destined for inside the history --------------------------
    final depthInjections = <({int depth, ChatMessage message})>[];
    for (final entry
        in lore?.at(WorldInfoPosition.atDepth) ?? const <WorldInfoEntry>[]) {
      final content = expander.expand(entry.content.trim());
      if (content.isEmpty) continue;
      final message = ChatMessage(
        role: ChatRole.fromName(entry.role),
        content: content,
        isSystemNote: true,
      );
      depthInjections.add((depth: entry.depth, message: message));
      allBlocks.add(
        PromptBlock(
          id: 'worldInfoDepth:${entry.uid}',
          role: message.role,
          content: content,
          source: PromptBlockSource.lore,
          tokenCost: tokenizer.count(content),
        ),
      );
    }

    // Author's Note, with AN Top/Bottom lore folded into it.
    final noteContent = _joinParts(<String>[
      _join(lore?.at(WorldInfoPosition.anTop)),
      authorNote ?? '',
      _join(lore?.at(WorldInfoPosition.anBottom)),
    ]);

    ChatMessage? noteMessage;
    if (noteContent.trim().isNotEmpty) {
      final content = expander.expand(noteContent.trim());
      noteMessage = ChatMessage(
        role: authorNoteRole,
        content: content,
        isSystemNote: true,
      );
      allBlocks.add(
        PromptBlock(
          id: 'authorsNote',
          role: authorNoteRole,
          content: content,
          source: PromptBlockSource.user,
          tokenCost: tokenizer.count(content),
        ),
      );
    }

    // --- budget the history against everything else ------------------------
    var nonHistoryCost = 0;
    for (final block in systemBlocks) {
      nonHistoryCost += block.tokenCost;
    }
    nonHistoryCost += postHistory?.tokenCost ?? 0;
    for (final injection in depthInjections) {
      nonHistoryCost += tokenizer.count(injection.message.content);
    }
    if (noteMessage != null) {
      nonHistoryCost += tokenizer.count(noteMessage.content);
    }

    final kept = <ChatMessage>[];
    final dropped = <ChatMessage>[];
    var historyCost = 0;

    if (contextBudget <= 0) {
      kept.addAll(history);
      for (final message in history) {
        historyCost += tokenizer.count(expander.expand(message.content));
      }
    } else {
      // Walk backwards: the most recent turns are the ones worth keeping, and
      // SillyTavern likewise drops the oldest history as context fills.
      var remaining = contextBudget - nonHistoryCost;
      for (var i = history.length - 1; i >= 0; i--) {
        final cost = tokenizer.count(expander.expand(history[i].content));
        if (remaining - cost < 0) {
          dropped.addAll(history.sublist(0, i + 1));
          break;
        }
        remaining -= cost;
        historyCost += cost;
        kept.insert(0, history[i]);
      }
    }

    // --- assemble ---------------------------------------------------------
    final messages = <ChatMessage>[
      for (final block in systemBlocks)
        ChatMessage(role: block.role, content: block.content),
      for (final message in kept)
        message.copyWith(content: expander.expand(message.content)),
    ];

    for (final injection in depthInjections) {
      _insertAtDepth(messages, injection.message, injection.depth);
    }
    if (noteMessage != null) {
      _insertAtDepth(messages, noteMessage, authorNoteDepth);
    }
    if (postHistory != null) {
      messages.add(
        ChatMessage(role: postHistory.role, content: postHistory.content),
      );
    }

    return AssembledPrompt(
      messages: messages,
      blocks: allBlocks,
      tokenCost: nonHistoryCost + historyCost,
      droppedForBudget: dropped,
      outlets: outlets,
    );
  }

  /// `depth` counts backwards from the end: 0 appends, 1 lands before the final
  /// message.
  void _insertAtDepth(
    List<ChatMessage> messages,
    ChatMessage message,
    int depth,
  ) {
    final index = (messages.length - depth).clamp(0, messages.length);
    messages.insert(index, message);
  }

  Map<String, String> _collectOutlets(WorldInfoScanResult? lore) {
    final outlets = <String, String>{};
    for (final entry
        in lore?.at(WorldInfoPosition.outlet) ?? const <WorldInfoEntry>[]) {
      final name = entry.outletName;
      if (name == null || name.isEmpty) continue;
      final existing = outlets[name];
      outlets[name] =
          existing == null ? entry.content : '$existing\n${entry.content}';
    }
    return outlets;
  }

  String _join(List<WorldInfoEntry>? entries) {
    if (entries == null || entries.isEmpty) return '';
    return entries.map((e) => e.content.trim()).join('\n');
  }

  /// Joins non-empty parts with newlines.
  ///
  /// Concatenating them directly would glue injected lore onto the text it is
  /// meant to sit beside — `ANTop + note + ANBottom` becomes one run-on string.
  String _joinParts(List<String> parts) {
    final kept = <String>[
      for (final part in parts)
        if (part.trim().isNotEmpty) part.trim(),
    ];
    return kept.join('\n');
  }
}
