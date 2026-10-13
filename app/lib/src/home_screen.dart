import 'package:decanter_core/decanter_core.dart';
import 'package:flutter/material.dart';

import 'glass.dart';

/// The main surface: a card, a chat, and a live view of what the lorebook is
/// doing.
///
/// The lore inspector is the point of this first build. It makes the engine's
/// decisions visible on a real device — which entries fired, from which keys,
/// and where they land in the prompt — so a bug in activation is something you
/// can see rather than infer.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.card});

  final TavernCard card;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();

  final List<ChatMessage> _history = <ChatMessage>[];
  final WorldInfoTiming _timing = WorldInfoTiming();

  WorldInfoScanResult? _scan;
  bool _inspectorOpen = true;

  @override
  void initState() {
    super.initState();
    _restart();
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  // --- chat ---------------------------------------------------------------

  void _restart() {
    final String greeting = widget.card.greetings.isEmpty
        ? '*She is here, and says nothing yet.*'
        : widget.card.greetings.first;

    _history
      ..clear()
      // A fresh timing state per chat, otherwise cooldowns leak across resets.
      ..add(ChatMessage(role: ChatRole.assistant, content: greeting));

    for (final String key in _timing.entries.keys.toList()) {
      _timing[key].stickyLeft = 0;
      _timing[key].cooldownLeft = 0;
      _timing[key].delayLeft = 0;
    }
    _scan = _runScan();
  }

  WorldInfoScanResult _runScan() {
    final CharacterBook? book = widget.card.characterBook;
    return WorldInfoScanner().scan(
      sources: book == null
          ? const <WorldInfoSource>[]
          : <WorldInfoSource>[WorldInfoSource(key: 'character', book: book)],
      history: _history,
      timing: _timing,
      // History only for now. SillyTavern can also scan the character
      // description and persona; that becomes a setting rather than a default,
      // because it makes lore fire before anyone has said anything.
      tokenBudget: 1024,
    );
  }

  void _send() {
    final String text = _input.text.trim();
    if (text.isEmpty) return;

    setState(() {
      _history.add(ChatMessage(role: ChatRole.user, content: text));
      _input.clear();
      _scan = _runScan();
      _history.add(
        const ChatMessage(
          role: ChatRole.assistant,
          isSystemNote: true,
          content:
              'No model backend is connected in this build, so there is no '
              'reply yet. Type lore keywords — furnace, sea glass, the '
              'accident — and watch the inspector below change.',
        ),
      );
    });
    _scrollToEnd();
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 520),
        curve: Curves.easeOutCubic,
      );
    });
  }

  // --- build --------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final CharacterBook? book = widget.card.characterBook;

    return Scaffold(
      backgroundColor: const Color.fromRGBO(12, 9, 8, 1),
      resizeToAvoidBottomInset: true,
      body: LiquidBackground(
        asset: 'assets/background.png',
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            child: Column(
              children: <Widget>[
                _header(book),
                const SizedBox(height: 12),
                Expanded(child: _messageList()),
                const SizedBox(height: 10),
                if (_scan != null) _inspector(_scan!),
                const SizedBox(height: 10),
                _composer(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _header(CharacterBook? book) {
    return GlassPanel(
      padding: const EdgeInsets.fromLTRB(12, 12, 14, 12),
      child: SheenSweep(
        child: Row(
          children: <Widget>[
            _avatar(),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    widget.card.name.isEmpty ? 'Unnamed card' : widget.card.name,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Glass.textPrimary,
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.1,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    <String>[
                      widget.card.spec.id.replaceFirst('chara_card_', ''),
                      '${widget.card.greetings.length} greeting'
                          '${widget.card.greetings.length == 1 ? '' : 's'}',
                      if (book != null)
                        '${book.entries.length} lore '
                            'entr${book.entries.length == 1 ? 'y' : 'ies'}',
                    ].join('  ·  '),
                    style: const TextStyle(
                      color: Glass.textFaint,
                      fontSize: 11.5,
                      letterSpacing: 0.3,
                    ),
                  ),
                ],
              ),
            ),
            _GhostButton(label: 'RESET', onTap: _restart),
          ],
        ),
      ),
    );
  }

  Widget _avatar() {
    final String initials = widget.card.name
        .split(RegExp(r'\s+'))
        .where((String w) => w.isNotEmpty)
        .take(2)
        .map((String w) => w.substring(0, 1).toUpperCase())
        .join();

    return GlassPanel(
      radius: 999,
      blur: 14,
      padding: EdgeInsets.zero,
      tintStrength: 1.3,
      shadow: false,
      child: SizedBox(
        width: 46,
        height: 46,
        child: Center(
          child: Text(
            initials.isEmpty ? '?' : initials,
            style: const TextStyle(
              color: Glass.textPrimary,
              fontWeight: FontWeight.w600,
              fontSize: 16,
            ),
          ),
        ),
      ),
    );
  }

  Widget _messageList() {
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.only(top: 2, bottom: 4),
      itemCount: _history.length,
      itemBuilder: (BuildContext context, int index) {
        final ChatMessage message = _history[index];
        return TweenAnimationBuilder<double>(
          // Keyed by index so each bubble animates once, on entry.
          key: ValueKey<int>(index),
          tween: Tween<double>(begin: 0, end: 1),
          duration: const Duration(milliseconds: 420),
          curve: Curves.easeOutCubic,
          builder: (BuildContext context, double t, Widget? child) {
            return Opacity(
              opacity: t,
              child: Transform.translate(
                offset: Offset(0, (1 - t) * 14),
                child: child,
              ),
            );
          },
          child: _bubble(message),
        );
      },
    );
  }

  Widget _bubble(ChatMessage message) {
    if (message.isSystemNote) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 8),
        child: Text(
          message.content,
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: Glass.textFaint,
            fontSize: 12,
            height: 1.4,
          ),
        ),
      );
    }

    final bool mine = message.role == ChatRole.user;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.78,
        ),
        margin: const EdgeInsets.symmetric(vertical: 5),
        child: GlassPanel(
          radius: 22,
          blur: mine ? 16 : 20,
          padding: const EdgeInsets.fromLTRB(15, 12, 15, 12),
          tintStrength: mine ? 1.25 : 0.85,
          shadow: false,
          child: Text(
            message.content.trim(),
            style: TextStyle(
              color: mine ? Glass.textPrimary : Glass.textSecondary,
              fontSize: 14.5,
              height: 1.42,
            ),
          ),
        ),
      ),
    );
  }

  Widget _inspector(WorldInfoScanResult scan) {
    final List<WorldInfoEntry> active = scan.activated;

    return GlassPanel(
      padding: const EdgeInsets.fromLTRB(14, 11, 14, 12),
      tintStrength: 0.8,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          GestureDetector(
            onTap: () => setState(() => _inspectorOpen = !_inspectorOpen),
            behavior: HitTestBehavior.opaque,
            child: Row(
              children: <Widget>[
                const Text(
                  'LOREBOOK',
                  style: TextStyle(
                    color: Glass.textSecondary,
                    fontSize: 10.5,
                    letterSpacing: 1.4,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  '${active.length} active  ·  ${scan.tokenCost} tok'
                  '${scan.excludedByBudget.isEmpty ? '' : '  ·  ${scan.excludedByBudget.length} over budget'}',
                  style: const TextStyle(color: Glass.textFaint, fontSize: 10.5),
                ),
                const Spacer(),
                AnimatedRotation(
                  turns: _inspectorOpen ? 0.5 : 0,
                  duration: const Duration(milliseconds: 260),
                  child: const Icon(
                    Icons.expand_more,
                    size: 16,
                    color: Glass.textFaint,
                  ),
                ),
              ],
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: _inspectorOpen
                ? Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: active.isEmpty
                        ? const Text(
                            'Nothing activated. Entry keys are matched against '
                            'recent messages.',
                            style: TextStyle(
                              color: Glass.textFaint,
                              fontSize: 11.5,
                              height: 1.35,
                            ),
                          )
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              for (final WorldInfoEntry entry in active)
                                _loreRow(entry),
                            ],
                          ),
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }

  Widget _loreRow(WorldInfoEntry entry) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Container(
            margin: const EdgeInsets.only(top: 5, right: 8),
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              color: Glass.tint(0.8),
              shape: BoxShape.circle,
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  entry.comment.isEmpty ? entry.keys.join(', ') : entry.comment,
                  style: const TextStyle(
                    color: Glass.textPrimary,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  '${entry.position.name}  ·  matched '
                  '${entry.keys.take(3).join(', ')}',
                  style: const TextStyle(color: Glass.textFaint, fontSize: 10.5),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _composer() {
    return GlassPill(
      padding: const EdgeInsets.fromLTRB(18, 4, 6, 4),
      child: Row(
        children: <Widget>[
          Expanded(
            child: TextField(
              controller: _input,
              onSubmitted: (_) => _send(),
              textInputAction: TextInputAction.send,
              style: const TextStyle(color: Glass.textPrimary, fontSize: 14.5),
              cursorColor: Glass.tint(0.9),
              decoration: const InputDecoration(
                isDense: true,
                border: InputBorder.none,
                hintText: 'Say something…',
                hintStyle: TextStyle(color: Glass.textFaint, fontSize: 14.5),
              ),
            ),
          ),
          GestureDetector(
            onTap: _send,
            child: const GlassPanel(
              radius: 999,
              blur: 10,
              padding: EdgeInsets.all(10),
              tintStrength: 1.6,
              shadow: false,
              showSpecular: false,
              child: Icon(
                Icons.arrow_upward_rounded,
                size: 18,
                color: Glass.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A small translucent text button.
class _GhostButton extends StatelessWidget {
  const _GhostButton({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: GlassPanel(
        radius: 999,
        blur: 12,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        showSpecular: false,
        shadow: false,
        child: Text(
          label,
          style: const TextStyle(
            color: Glass.textSecondary,
            fontSize: 9.5,
            letterSpacing: 1.2,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}
