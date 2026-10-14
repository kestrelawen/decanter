import 'dart:io';

import 'package:decanter_core/decanter_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'chat_content.dart';
import 'chat_controller.dart';
import 'glass.dart';
import 'settings.dart';

/// The main surface: the card, the conversation, and the reply arriving.
class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.card,
    required this.settings,
    required this.onOpenSettings,
    this.store,
    this.entryId,
  });

  final TavernCard card;
  final AppSettings settings;
  final Future<void> Function() onOpenSettings;

  /// Where the conversation is kept. Nullable so the screen still works
  /// standalone — in a widget test, or with a card that has no library entry.
  final LibraryStore? store;

  /// The library entry this conversation belongs to. Required to persist.
  final String? entryId;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late ChatController _chat;
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();

  int get _greetingIndex =>
      (_chat.history.isNotEmpty && _chat.history.first.swipes.isNotEmpty)
          ? _chat.history.first.swipeIndex
          : 0;

  /// Revision of the chat when it was last saved, so unchanged state does not
  /// rewrite the file.
  int _lastSavedRevision = -1;

  /// Identifier of the active conversation thread.
  String? _activeChatId;

  @override
  void initState() {
    super.initState();
    _chat = ChatController(card: widget.card, settings: widget.settings)
      ..addListener(_onChatChanged);
    _restoreChat();
  }

  /// Picks the conversation up where the last visit left it.
  void _restoreChat() {
    final LibraryStore? store = widget.store;
    final String? id = widget.entryId;
    if (store == null || id == null) return;

    final StoredChat saved = store.loadChat(id);
    _activeChatId = saved.id.isEmpty ? 'main' : saved.id;
    if (saved.isEmpty) return;

    _chat.replaceHistory(saved.messages);
    _lastSavedRevision = _chat.revision;
  }

  @override
  void didUpdateWidget(HomeScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.settings, widget.settings)) {
      _chat.updateSettings(widget.settings);
    }
  }

  @override
  void dispose() {
    _chat
      ..removeListener(_onChatChanged)
      ..dispose();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onChatChanged() {
    if (!mounted) return;
    setState(() {});
    _follow();
    _persist();
  }

  /// Saves the conversation once a turn has settled.
  ///
  /// Deliberately not on every streamed token: that would rewrite the file
  /// hundreds of times per reply for no benefit, because the recoverable state
  /// is the last settled one either way.
  bool _cleared = false;

  void _persist() {
    final LibraryStore? store = widget.store;
    final String? id = widget.entryId;
    if (store == null || id == null || _chat.isStreaming || _cleared) return;

    if (_chat.revision == _lastSavedRevision) return;
    _lastSavedRevision = _chat.revision;
    store.saveChat(id, _chat.history, chatId: _activeChatId);
  }

  /// Abandons the conversation and starts again from the greeting.
  ///
  /// The stored copy is cleared as well, so "new chat" means new on the next
  /// launch rather than resurrecting what was just discarded.
  void _startFresh() {
    final LibraryStore? store = widget.store;
    final String? id = widget.entryId;
    if (store != null && id != null) {
      store.clearChat(id, _activeChatId);
    }

    _cleared = true;
    _chat.reset();
    _lastSavedRevision = _chat.revision;
  }

  void _switchChat(String chatId) {
    final LibraryStore? store = widget.store;
    final String? id = widget.entryId;
    if (store == null || id == null) return;

    if (!_chat.isStreaming &&
        !_cleared &&
        _chat.revision != _lastSavedRevision) {
      store.saveChat(id, _chat.history, chatId: _activeChatId);
      _lastSavedRevision = _chat.revision;
    }

    final StoredChat target = store.loadChat(id, chatId);
    _activeChatId = chatId;
    _cleared = false;
    _chat.replaceHistory(target.messages);
    _lastSavedRevision = _chat.revision;
    _follow();
  }

  void _createNewChat({String? title, List<ChatMessage>? initialMessages}) {
    final LibraryStore? store = widget.store;
    final String? id = widget.entryId;
    if (store == null || id == null) {
      _startFresh();
      return;
    }

    if (!_chat.isStreaming &&
        !_cleared &&
        _chat.revision != _lastSavedRevision) {
      store.saveChat(id, _chat.history, chatId: _activeChatId);
      _lastSavedRevision = _chat.revision;
    }

    final List<ChatMessage> initial = initialMessages ??
        <ChatMessage>[
          ChatMessage(
            role: ChatRole.assistant,
            content: widget.card.greeting,
          ),
        ];

    final StoredChat created = store.createNewChat(
      id,
      title: title,
      initialMessages: initial,
    );

    _activeChatId = created.id;
    _cleared = false;
    _chat.replaceHistory(created.messages);
    _lastSavedRevision = _chat.revision;
    _follow();
  }

  void _branchFromMessage(int messageIndex) {
    final LibraryStore? store = widget.store;
    final String? id = widget.entryId;
    if (store == null || id == null) return;

    if (!_chat.isStreaming &&
        !_cleared &&
        _chat.revision != _lastSavedRevision) {
      store.saveChat(id, _chat.history, chatId: _activeChatId);
      _lastSavedRevision = _chat.revision;
    }

    final StoredChat branched = store.forkChat(
      id,
      _activeChatId ?? 'main',
      messageIndex,
      newTitle: 'Branch #${messageIndex + 1}',
    );

    _activeChatId = branched.id;
    _cleared = false;
    _chat.replaceHistory(branched.messages);
    _lastSavedRevision = _chat.revision;
    _follow();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Branched to "${branched.title}"'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  void _forkChatThread(StoredChat chat) {
    final LibraryStore? store = widget.store;
    final String? id = widget.entryId;
    if (store == null || id == null) return;

    final StoredChat branched = store.forkChat(
      id,
      chat.id,
      chat.messages.isEmpty ? 0 : chat.messages.length - 1,
      newTitle: '${chat.title.isEmpty ? "Chat" : chat.title} (Copy)',
    );

    _activeChatId = branched.id;
    _cleared = false;
    _chat.replaceHistory(branched.messages);
    _lastSavedRevision = _chat.revision;
    _follow();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Switched to "${branched.title}"'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  /// Keeps the newest content in view, but only when the user is already near
  /// the bottom — yanking the viewport while someone is reading back through the
  /// conversation is worse than letting the reply run off-screen.
  void _follow() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final double max = _scroll.position.maxScrollExtent;
      if ((_scroll.position.pixels - max).abs() > 180) return;
      _scroll.animateTo(
        max,
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
      );
    });
  }

  void _send() {
    _cleared = false;
    final String text = _input.text.trim();
    if (text.isEmpty || _chat.isStreaming) return;
    _input.clear();

    if (text.startsWith('/note ') ||
        text.startsWith('/sys ') ||
        text.startsWith('/narration ')) {
      final String note =
          text.replaceFirst(RegExp(r'^/(note|sys|narration)\s+'), '');
      _chat.addNarratorNote(note);
      _follow();
      return;
    }

    // Deliberately not awaited: the UI stays responsive while the reply streams.
    _chat.send(text);
    _follow();
  }

  void _cycleGreeting() {
    final int count = widget.card.greetings.length;
    if (count < 2 || _chat.history.isEmpty) return;
    final int next = (_greetingIndex + 1) % count;
    _chat.useGreeting(next);
  }

  // --- build --------------------------------------------------------------

  /// The card's own picture, when the card has one.
  ///
  /// Looked up once per build rather than per reference, because finding it
  /// means listing the card's directory.
  File? get _cardArt {
    final LibraryStore? store = widget.store;
    final String? id = widget.entryId;
    if (store == null || id == null) return null;
    return store.imageFile(id);
  }

  @override
  Widget build(BuildContext context) {
    final File? art = _cardArt;

    return Scaffold(
      backgroundColor: const Color.fromRGBO(12, 9, 8, 1),
      body: LiquidBackground(
        image: art == null
            ? const AssetImage('assets/background.png')
            : FileImage(art),
        // A JSON card falls back to the generated backdrop; a character portrait
        // is far more detailed, so text over it needs a heavier scrim.
        scrim: art == null ? 1.0 : 1.35,
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            child: Column(
              children: <Widget>[
                _header(),
                const SizedBox(height: 10),
                Expanded(child: _messageList()),
                if (_chat.error != null) ...<Widget>[
                  const SizedBox(height: 10),
                  _errorBanner(_chat.error!),
                ],
                const SizedBox(height: 10),
                _composer(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _header() {
    final WorldInfoScanResult? scan = _chat.scan;
    final int greetingCount = widget.card.greetings.length;
    final int active = scan?.activated.length ?? 0;

    return GlassPanel(
      padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
      child: SheenSweep(
        child: Row(
          children: <Widget>[
            // Only shown when this screen was pushed. Sitting at the root, a back
            // arrow would have nowhere to go, and a dead control is worse than
            // no control.
            if (Navigator.of(context).canPop()) ...<Widget>[
              _IconAction(
                icon: Icons.arrow_back_rounded,
                onTap: () => Navigator.of(context).maybePop(),
              ),
              const SizedBox(width: 9),
            ],
            _avatar(),
            const SizedBox(width: 11),
            Expanded(
              child: GestureDetector(
                // Tapping cycles alternate greetings — the only way to reach the
                // second opening without editing the card.
                onTap: greetingCount > 1 ? _cycleGreeting : null,
                behavior: HitTestBehavior.opaque,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      widget.card.name.isEmpty
                          ? 'Unnamed card'
                          : widget.card.name,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Glass.textPrimary,
                        fontSize: 16.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      <String>[
                        '${scan?.tokenCost ?? 0} tok',
                        '$active lore',
                        if (greetingCount > 1)
                          'greeting ${_greetingIndex + 1}/$greetingCount',
                        if (!widget.settings.isConfigured) 'no backend',
                      ].join('  ·  '),
                      style: const TextStyle(
                        color: Glass.textFaint,
                        fontSize: 10.5,
                        letterSpacing: 0.3,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (widget.store != null && widget.entryId != null) ...<Widget>[
              _IconAction(
                icon: Icons.forum_outlined,
                tooltip: 'Chats',
                onTap: _openChatsSheet,
              ),
              const SizedBox(width: 6),
            ],
            _IconAction(
              icon: Icons.auto_awesome_motion_outlined,
              tooltip: 'Lorebook',
              onTap: _openLoreSheet,
              badge: active > 0 ? '$active' : null,
            ),
            const SizedBox(width: 6),
            _IconAction(
              icon: Icons.tune_rounded,
              tooltip: 'Settings',
              onTap: widget.onOpenSettings,
            ),
            const SizedBox(width: 6),
            _IconAction(
              icon: Icons.refresh_rounded,
              tooltip: 'Restart chat',
              onTap: _startFresh,
            ),
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
        width: 42,
        height: 42,
        child: Center(
          child: Text(
            initials.isEmpty ? '?' : initials,
            style: const TextStyle(
              color: Glass.textPrimary,
              fontWeight: FontWeight.w600,
              fontSize: 15,
            ),
          ),
        ),
      ),
    );
  }

  Widget _messageList() {
    final List<ChatMessage> history = _chat.history;
    final int extra = (_chat.isStreaming &&
            _chat.regeneratingIndex == null &&
            _chat.continuingIndex == null)
        ? 1
        : 0;

    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.only(top: 2, bottom: 4),
      itemCount: history.length + extra,
      itemBuilder: (BuildContext context, int index) {
        if (index >= history.length) {
          return KeyedSubtree(
            key: const ValueKey<String>('streaming'),
            child: _bubble(
              ChatMessage(
                role: ChatRole.assistant,
                content: _chat.streamingText,
              ),
              streaming: true,
            ),
          );
        }

        final bool isRegeneratingThis =
            _chat.isStreaming && _chat.regeneratingIndex == index;
        final bool isContinuingThis =
            _chat.isStreaming && _chat.continuingIndex == index;
        final ChatMessage message = isRegeneratingThis
            ? history[index].copyWith(content: _chat.streamingText)
            : (isContinuingThis
                ? history[index].withAppendedContent(_chat.streamingText)
                : history[index]);

        return KeyedSubtree(
          key: ValueKey<int>(index),
          child: _bubble(
            message,
            messageIndex: index,
            streaming: isRegeneratingThis || isContinuingThis,
          ),
        );
      },
    );
  }

  Widget _bubble(
    ChatMessage message, {
    int? messageIndex,
    bool streaming = false,
  }) {
    if (message.isSystemNote) {
      return GestureDetector(
        behavior: HitTestBehavior.translucent,
        onLongPress: (!streaming && messageIndex != null)
            ? () => _showMessageActions(messageIndex)
            : null,
        child: Padding(
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
        ),
      );
    }

    final bool mine = message.role == ChatRole.user;
    final String text = message.content.trim();
    final List<ChatMessage> history = _chat.history;
    final bool isLastAssistant = !mine &&
        messageIndex != null &&
        messageIndex ==
            history.lastIndexWhere(
              (ChatMessage m) => m.role == ChatRole.assistant,
            );
    final bool showSwipeControls = !mine &&
        !streaming &&
        messageIndex != null &&
        (message.hasSwipes || isLastAssistant);

    final Widget bubbleContent = Align(
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
          child: Column(
            crossAxisAlignment:
                mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              text.isEmpty && streaming
                  ? const _ThinkingDots()
                  : ChatRichContent(
                      text: text,
                      isUser: mine,
                    ),
              if (showSwipeControls) ...<Widget>[
                const SizedBox(height: 8),
                _swipeToolbar(message, messageIndex, isLastAssistant),
              ],
            ],
          ),
        ),
      ),
    );

    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onLongPress: (!streaming && messageIndex != null)
          ? () => _showMessageActions(messageIndex)
          : null,
      onHorizontalDragEnd: (!mine && !streaming && messageIndex != null)
          ? (DragEndDetails details) {
              final double? velocity = details.primaryVelocity;
              if (velocity == null) return;
              if (velocity < -120) {
                // Swiped left (finger drags right-to-left) -> next swipe or regenerate
                if (message.canSwipeRight) {
                  _chat.nextSwipe(messageIndex);
                } else if (isLastAssistant && !_chat.isStreaming) {
                  _chat.regenerate(messageIndex: messageIndex);
                }
              } else if (velocity > 120) {
                // Swiped right (finger drags left-to-right) -> previous swipe
                if (message.canSwipeLeft) {
                  _chat.previousSwipe(messageIndex);
                }
              }
            }
          : null,
      child: bubbleContent,
    );
  }

  Widget _swipeToolbar(
    ChatMessage message,
    int messageIndex,
    bool isLastAssistant,
  ) {
    final bool canLeft = message.canSwipeLeft;
    final bool canRight = message.canSwipeRight;
    final int total = message.swipes.length;
    final int current = message.swipeIndex + 1;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (total > 1) ...<Widget>[
          GestureDetector(
            onTap: canLeft ? () => _chat.previousSwipe(messageIndex) : null,
            behavior: HitTestBehavior.opaque,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              child: Icon(
                Icons.chevron_left_rounded,
                size: 18,
                color: canLeft ? Glass.textSecondary : Glass.tint(0.2),
              ),
            ),
          ),
          Text(
            '$current/$total',
            style: const TextStyle(
              color: Glass.textFaint,
              fontSize: 11,
              fontWeight: FontWeight.w500,
              letterSpacing: 0.5,
            ),
          ),
          GestureDetector(
            onTap: canRight ? () => _chat.nextSwipe(messageIndex) : null,
            behavior: HitTestBehavior.opaque,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              child: Icon(
                Icons.chevron_right_rounded,
                size: 18,
                color: canRight ? Glass.textSecondary : Glass.tint(0.2),
              ),
            ),
          ),
        ],
        if (isLastAssistant) ...<Widget>[
          if (total > 1) const SizedBox(width: 8),
          GestureDetector(
            onTap: _chat.isStreaming
                ? null
                : () => _chat.regenerate(messageIndex: messageIndex),
            behavior: HitTestBehavior.opaque,
            child: Tooltip(
              message: 'Regenerate',
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: const <Widget>[
                    Icon(
                      Icons.sync_rounded,
                      size: 14,
                      color: Glass.textSecondary,
                    ),
                    SizedBox(width: 3),
                    Text(
                      'RETRY',
                      style: TextStyle(
                        color: Glass.textSecondary,
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.8,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          GestureDetector(
            onTap: _chat.isStreaming
                ? null
                : () => _chat.continueGeneration(messageIndex: messageIndex),
            behavior: HitTestBehavior.opaque,
            child: Tooltip(
              message: 'Continue writing',
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: const <Widget>[
                    Icon(
                      Icons.fast_forward_rounded,
                      size: 14,
                      color: Glass.textSecondary,
                    ),
                    SizedBox(width: 3),
                    Text(
                      'CONTINUE',
                      style: TextStyle(
                        color: Glass.textSecondary,
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.8,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
        if (total > 1) ...<Widget>[
          const SizedBox(width: 6),
          GestureDetector(
            onTap: _chat.isStreaming
                ? null
                : () => _chat.deleteSwipe(messageIndex, message.swipeIndex),
            behavior: HitTestBehavior.opaque,
            child: Tooltip(
              message: 'Delete swipe',
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                child: Icon(
                  Icons.delete_outline_rounded,
                  size: 14,
                  color: Glass.tint(0.4),
                ),
              ),
            ),
          ),
        ],
        const SizedBox(width: 6),
        GestureDetector(
          onTap: () => _showMessageActions(messageIndex),
          behavior: HitTestBehavior.opaque,
          child: Tooltip(
            message: 'Message actions',
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              child: Icon(
                Icons.more_horiz_rounded,
                size: 16,
                color: Glass.tint(0.45),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _errorBanner(String message) {
    return GlassPanel(
      padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
      tintStrength: 1.1,
      borderStrength: 1.4,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Icon(
            Icons.error_outline_rounded,
            size: 16,
            color: Glass.textSecondary,
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(
                color: Glass.textSecondary,
                fontSize: 11.5,
                height: 1.4,
              ),
            ),
          ),
          GestureDetector(
            onTap: _chat.removeLastExchange,
            child: const Padding(
              padding: EdgeInsets.only(left: 8),
              child: Text(
                'RETRY',
                style: TextStyle(
                  color: Glass.textPrimary,
                  fontSize: 10,
                  letterSpacing: 1.2,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _composer() {
    final bool streaming = _chat.isStreaming;

    return GlassPill(
      padding: const EdgeInsets.fromLTRB(18, 4, 6, 4),
      child: Row(
        children: <Widget>[
          Expanded(
            child: TextField(
              controller: _input,
              onSubmitted: (_) => _send(),
              textInputAction: TextInputAction.send,
              minLines: 1,
              maxLines: 4,
              style: const TextStyle(color: Glass.textPrimary, fontSize: 14.5),
              cursorColor: Glass.tint(0.9),
              decoration: const InputDecoration(
                isDense: true,
                border: InputBorder.none,
                hintText: 'Say something… (/note for narration)',
                hintStyle: TextStyle(color: Glass.textFaint, fontSize: 14.5),
              ),
            ),
          ),
          GestureDetector(
            onTap: streaming ? _chat.stop : _send,
            onLongPress: streaming ? null : _showComposerOptions,
            child: GlassPanel(
              radius: 999,
              blur: 10,
              padding: const EdgeInsets.all(10),
              tintStrength: 1.6,
              shadow: false,
              showSpecular: false,
              child: Icon(
                streaming ? Icons.stop_rounded : Icons.arrow_upward_rounded,
                size: 18,
                color: Glass.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // --- message actions & editing -------------------------------------------

  void _showMessageActions(int messageIndex) {
    if (messageIndex < 0 || messageIndex >= _chat.history.length) return;
    final ChatMessage message = _chat.history[messageIndex];
    final bool isUser = message.role == ChatRole.user;
    final bool isAssistant = message.role == ChatRole.assistant;

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (BuildContext sheetContext) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 16),
          child: GlassPanel(
            radius: 28,
            blur: 32,
            padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
            tintStrength: 1.4,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Glass.tint(0.3),
                      borderRadius: BorderRadius.circular(99),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  isUser
                      ? 'USER MESSAGE'
                      : (isAssistant
                          ? '${widget.card.name.toUpperCase()} · ${message.hasSwipes ? 'SWIPE ${message.swipeIndex + 1}/${message.swipes.length}' : 'REPLY'}'
                          : 'NARRATOR NOTE'),
                  style: const TextStyle(
                    color: Glass.textFaint,
                    fontSize: 10.5,
                    letterSpacing: 1.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 12),
                _actionTile(
                  icon: Icons.edit_outlined,
                  label: 'Edit message',
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    _showEditDialog(messageIndex);
                  },
                ),
                _actionTile(
                  icon: Icons.copy_rounded,
                  label: 'Copy text',
                  onTap: () async {
                    Navigator.of(sheetContext).pop();
                    await Clipboard.setData(
                      ClipboardData(text: message.content),
                    );
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Copied to clipboard'),
                          duration: Duration(seconds: 1),
                        ),
                      );
                    }
                  },
                ),
                if (isAssistant && !_chat.isStreaming) ...<Widget>[
                  _actionTile(
                    icon: Icons.fast_forward_rounded,
                    label: 'Continue writing',
                    onTap: () {
                      Navigator.of(sheetContext).pop();
                      _chat.continueGeneration(messageIndex: messageIndex);
                    },
                  ),
                  _actionTile(
                    icon: Icons.sync_rounded,
                    label: 'Regenerate (new swipe)',
                    onTap: () {
                      Navigator.of(sheetContext).pop();
                      _chat.regenerate(messageIndex: messageIndex);
                    },
                  ),
                ],
                if (widget.store != null && widget.entryId != null) ...<Widget>[
                  _actionTile(
                    icon: Icons.fork_right_rounded,
                    label: 'Branch conversation from here',
                    onTap: () {
                      Navigator.of(sheetContext).pop();
                      _branchFromMessage(messageIndex);
                    },
                  ),
                ],
                _actionTile(
                  icon: Icons.content_cut_rounded,
                  label: 'Prune from here to end',
                  color: const Color.fromRGBO(240, 140, 140, 1),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    _confirmPrune(messageIndex);
                  },
                ),
                _actionTile(
                  icon: Icons.delete_outline_rounded,
                  label: 'Delete message',
                  color: const Color.fromRGBO(240, 140, 140, 1),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    _chat.deleteMessage(messageIndex);
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _actionTile({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    Color? color,
  }) {
    final Color itemColor = color ?? Glass.textPrimary;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
        child: Row(
          children: <Widget>[
            Icon(icon, size: 19, color: itemColor),
            const SizedBox(width: 14),
            Text(
              label,
              style: TextStyle(
                color: itemColor,
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showEditDialog(int messageIndex) {
    if (messageIndex < 0 || messageIndex >= _chat.history.length) return;
    final ChatMessage message = _chat.history[messageIndex];
    final TextEditingController editController =
        TextEditingController(text: message.content);

    showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) {
        return Dialog(
          backgroundColor: Colors.transparent,
          insetPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
          child: GlassPanel(
            radius: 24,
            blur: 28,
            padding: const EdgeInsets.all(20),
            tintStrength: 1.4,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: <Widget>[
                    const Text(
                      'EDIT MESSAGE',
                      style: TextStyle(
                        color: Glass.textPrimary,
                        fontSize: 12,
                        letterSpacing: 1.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(
                        Icons.close_rounded,
                        size: 18,
                        color: Glass.textFaint,
                      ),
                      onPressed: () => Navigator.of(dialogContext).pop(),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Container(
                  constraints: const BoxConstraints(maxHeight: 260),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: Glass.shade(0.35),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: Glass.tint(0.15), width: 0.8),
                  ),
                  child: TextField(
                    controller: editController,
                    maxLines: null,
                    style:
                        const TextStyle(color: Glass.textPrimary, fontSize: 14),
                    cursorColor: Glass.tint(0.9),
                    decoration: const InputDecoration(
                      isDense: true,
                      border: InputBorder.none,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: <Widget>[
                    TextButton(
                      onPressed: () => Navigator.of(dialogContext).pop(),
                      child: const Text(
                        'CANCEL',
                        style: TextStyle(
                          color: Glass.textFaint,
                          fontSize: 11,
                          letterSpacing: 1,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Glass.tint(0.2),
                        foregroundColor: Glass.textPrimary,
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      onPressed: () {
                        final String newText = editController.text.trim();
                        if (newText.isNotEmpty) {
                          _chat.editMessage(messageIndex, newText);
                        }
                        Navigator.of(dialogContext).pop();
                      },
                      child: const Text(
                        'SAVE',
                        style: TextStyle(
                          fontSize: 11,
                          letterSpacing: 1,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _confirmPrune(int messageIndex) {
    showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          backgroundColor: const Color.fromRGBO(24, 18, 16, 0.95),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: const Text(
            'Prune conversation?',
            style: TextStyle(color: Glass.textPrimary, fontSize: 16),
          ),
          content: const Text(
            'This will delete this message and all messages that follow it.',
            style: TextStyle(color: Glass.textSecondary, fontSize: 13),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('CANCEL',
                  style: TextStyle(color: Glass.textFaint)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color.fromRGBO(180, 50, 50, 0.8),
                foregroundColor: Colors.white,
              ),
              onPressed: () {
                Navigator.of(dialogContext).pop();
                _chat.pruneFrom(messageIndex);
              },
              child: const Text('PRUNE'),
            ),
          ],
        );
      },
    );
  }

  void _showComposerOptions() {
    final String text = _input.text.trim();
    if (text.isEmpty) return;

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (BuildContext sheetContext) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 16),
          child: GlassPanel(
            radius: 24,
            blur: 28,
            padding: const EdgeInsets.all(16),
            tintStrength: 1.4,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                _actionTile(
                  icon: Icons.send_rounded,
                  label: 'Send message (triggers reply)',
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    _send();
                  },
                ),
                _actionTile(
                  icon: Icons.bookmark_add_outlined,
                  label: 'Insert as Narrator Note (no reply)',
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    _input.clear();
                    _chat.addNarratorNote(text);
                    _follow();
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // --- chat threads sheet -------------------------------------------------

  String _formatTimestamp(DateTime? time) {
    if (time == null) return '';
    final Duration diff = DateTime.now().difference(time);
    if (diff.inSeconds < 60) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${time.month}/${time.day}';
  }

  void _openChatsSheet() {
    final LibraryStore? store = widget.store;
    final String? id = widget.entryId;
    if (store == null || id == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Chat management requires a saved card.')),
      );
      return;
    }

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (BuildContext sheetContext) {
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setSheetState) {
            final List<StoredChat> chats = store.listChats(id);
            final String activeId =
                _activeChatId ?? (chats.isNotEmpty ? chats.first.id : 'main');

            return Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 14),
              child: GlassPanel(
                radius: 30,
                blur: 34,
                padding: const EdgeInsets.fromLTRB(18, 12, 18, 22),
                tintStrength: 1.5,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Center(
                      child: Container(
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                          color: Glass.tint(0.35),
                          borderRadius: BorderRadius.circular(99),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: <Widget>[
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            const Text(
                              'CHATS',
                              style: TextStyle(
                                color: Glass.textPrimary,
                                fontSize: 12,
                                letterSpacing: 1.6,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '${chats.length} ${chats.length == 1 ? 'conversation' : 'conversations'}',
                              style: const TextStyle(
                                color: Glass.textFaint,
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ),
                        ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Glass.tint(0.25),
                            foregroundColor: Glass.textPrimary,
                            elevation: 0,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 8,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                              side: BorderSide(
                                color: Glass.tint(0.2),
                                width: 0.8,
                              ),
                            ),
                          ),
                          icon: const Icon(Icons.add_rounded, size: 16),
                          label: const Text(
                            'NEW CHAT',
                            style: TextStyle(
                              fontSize: 10.5,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 1,
                            ),
                          ),
                          onPressed: () {
                            Navigator.of(sheetContext).pop();
                            _createNewChat();
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight: MediaQuery.of(context).size.height * 0.5,
                      ),
                      child: chats.isEmpty
                          ? const Padding(
                              padding: EdgeInsets.symmetric(vertical: 24),
                              child: Center(
                                child: Text(
                                  'No saved chats yet.',
                                  style: TextStyle(
                                    color: Glass.textFaint,
                                    fontSize: 13,
                                  ),
                                ),
                              ),
                            )
                          : ListView.separated(
                              shrinkWrap: true,
                              itemCount: chats.length,
                              separatorBuilder: (_, __) =>
                                  const SizedBox(height: 8),
                              itemBuilder: (BuildContext _, int index) {
                                final StoredChat chat = chats[index];
                                final bool isActive = chat.id == activeId;

                                return _chatRow(
                                  chat: chat,
                                  isActive: isActive,
                                  onSelect: () {
                                    Navigator.of(sheetContext).pop();
                                    if (!isActive) _switchChat(chat.id);
                                  },
                                  onRename: () {
                                    _showRenameChatDialog(sheetContext, chat,
                                        () {
                                      setSheetState(() {});
                                    });
                                  },
                                  onFork: () {
                                    Navigator.of(sheetContext).pop();
                                    _forkChatThread(chat);
                                  },
                                  onDelete: () {
                                    _confirmDeleteChat(sheetContext, chat, () {
                                      if (chat.id == activeId) {
                                        final List<StoredChat> remaining =
                                            store.listChats(id);
                                        if (remaining.isNotEmpty) {
                                          _switchChat(remaining.first.id);
                                        } else {
                                          _createNewChat();
                                        }
                                      }
                                      setSheetState(() {});
                                    });
                                  },
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _chatRow({
    required StoredChat chat,
    required bool isActive,
    required VoidCallback onSelect,
    required VoidCallback onRename,
    required VoidCallback onFork,
    required VoidCallback onDelete,
  }) {
    final String timeStr = _formatTimestamp(chat.savedAt ?? chat.createdAt);

    return InkWell(
      onTap: onSelect,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        decoration: BoxDecoration(
          color: isActive ? Glass.tint(0.18) : Glass.shade(0.22),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isActive ? Glass.tint(0.55) : Glass.tint(0.08),
            width: isActive ? 1.2 : 0.6,
          ),
        ),
        child: Row(
          children: <Widget>[
            Icon(
              isActive
                  ? Icons.check_circle_rounded
                  : Icons.chat_bubble_outline_rounded,
              size: 20,
              color: isActive ? Glass.tint(0.9) : Glass.textFaint,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Flexible(
                        child: Text(
                          chat.title.isEmpty ? 'Chat' : chat.title,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: isActive
                                ? Glass.textPrimary
                                : Glass.textSecondary,
                            fontSize: 13.5,
                            fontWeight:
                                isActive ? FontWeight.w600 : FontWeight.w500,
                          ),
                        ),
                      ),
                      if (timeStr.isNotEmpty) ...<Widget>[
                        const SizedBox(width: 8),
                        Text(
                          timeStr,
                          style: const TextStyle(
                            color: Glass.textFaint,
                            fontSize: 10,
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    chat.preview.isNotEmpty
                        ? chat.preview
                        : '${chat.messageCount} ${chat.messageCount == 1 ? 'message' : 'messages'}',
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                    style: const TextStyle(
                      color: Glass.textFaint,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
            PopupMenuButton<String>(
              icon: const Icon(
                Icons.more_vert_rounded,
                size: 18,
                color: Glass.textFaint,
              ),
              color: const Color.fromRGBO(28, 22, 20, 0.98),
              elevation: 4,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
                side: BorderSide(color: Glass.tint(0.2), width: 0.8),
              ),
              onSelected: (String value) {
                switch (value) {
                  case 'rename':
                    onRename();
                    break;
                  case 'fork':
                    onFork();
                    break;
                  case 'delete':
                    onDelete();
                    break;
                }
              },
              itemBuilder: (BuildContext _) => <PopupMenuEntry<String>>[
                const PopupMenuItem<String>(
                  value: 'rename',
                  child: Row(
                    children: <Widget>[
                      Icon(Icons.edit_outlined,
                          size: 16, color: Glass.textPrimary),
                      SizedBox(width: 10),
                      Text('Rename',
                          style: TextStyle(
                              color: Glass.textPrimary, fontSize: 13)),
                    ],
                  ),
                ),
                const PopupMenuItem<String>(
                  value: 'fork',
                  child: Row(
                    children: <Widget>[
                      Icon(Icons.fork_right_rounded,
                          size: 16, color: Glass.textPrimary),
                      SizedBox(width: 10),
                      Text('Duplicate / Branch',
                          style: TextStyle(
                              color: Glass.textPrimary, fontSize: 13)),
                    ],
                  ),
                ),
                const PopupMenuItem<String>(
                  value: 'delete',
                  child: Row(
                    children: <Widget>[
                      Icon(Icons.delete_outline_rounded,
                          size: 16, color: Color.fromRGBO(240, 140, 140, 1)),
                      SizedBox(width: 10),
                      Text('Delete',
                          style: TextStyle(
                              color: Color.fromRGBO(240, 140, 140, 1),
                              fontSize: 13)),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _showRenameChatDialog(
      BuildContext sheetContext, StoredChat chat, VoidCallback onRenamed) {
    final TextEditingController titleController =
        TextEditingController(text: chat.title);
    showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) {
        return Dialog(
          backgroundColor: Colors.transparent,
          insetPadding:
              const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
          child: GlassPanel(
            radius: 24,
            blur: 28,
            padding: const EdgeInsets.all(20),
            tintStrength: 1.4,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Text(
                  'RENAME CHAT',
                  style: TextStyle(
                    color: Glass.textPrimary,
                    fontSize: 12,
                    letterSpacing: 1.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 14),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: Glass.shade(0.35),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: Glass.tint(0.15), width: 0.8),
                  ),
                  child: TextField(
                    controller: titleController,
                    autofocus: true,
                    style:
                        const TextStyle(color: Glass.textPrimary, fontSize: 14),
                    cursorColor: Glass.tint(0.9),
                    decoration: const InputDecoration(
                      isDense: true,
                      border: InputBorder.none,
                      hintText: 'Chat title',
                      hintStyle: TextStyle(color: Glass.textFaint),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: <Widget>[
                    TextButton(
                      onPressed: () => Navigator.of(dialogContext).pop(),
                      child: const Text('CANCEL',
                          style: TextStyle(color: Glass.textFaint)),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Glass.tint(0.2),
                        foregroundColor: Glass.textPrimary,
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      onPressed: () {
                        final String newTitle = titleController.text.trim();
                        if (newTitle.isNotEmpty &&
                            widget.store != null &&
                            widget.entryId != null) {
                          widget.store!
                              .renameChat(widget.entryId!, chat.id, newTitle);
                          onRenamed();
                        }
                        Navigator.of(dialogContext).pop();
                      },
                      child: const Text('RENAME'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _confirmDeleteChat(
      BuildContext sheetContext, StoredChat chat, VoidCallback onDeleted) {
    showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          backgroundColor: const Color.fromRGBO(24, 18, 16, 0.95),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: const Text(
            'Delete chat?',
            style: TextStyle(color: Glass.textPrimary, fontSize: 16),
          ),
          content: Text(
            'Are you sure you want to delete "${chat.title}"? This cannot be undone.',
            style: const TextStyle(color: Glass.textSecondary, fontSize: 13),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('CANCEL',
                  style: TextStyle(color: Glass.textFaint)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color.fromRGBO(180, 50, 50, 0.8),
                foregroundColor: Colors.white,
              ),
              onPressed: () {
                Navigator.of(dialogContext).pop();
                if (widget.store != null && widget.entryId != null) {
                  widget.store!.deleteChat(widget.entryId!, chat.id);
                  onDeleted();
                }
              },
              child: const Text('DELETE'),
            ),
          ],
        );
      },
    );
  }

  // --- lore sheet ---------------------------------------------------------

  /// The lorebook readout used to sit permanently along the bottom, taking
  /// vertical space from the conversation it was describing. It now lives behind
  /// the header button: one tap away, and out of the way.
  void _openLoreSheet() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (BuildContext sheetContext) {
        final WorldInfoScanResult? scan = _chat.scan;
        final AssembledPrompt? prompt = _chat.lastPrompt;

        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 14),
          child: GlassPanel(
            radius: 30,
            blur: 34,
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 22),
            tintStrength: 1.5,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Glass.tint(0.35),
                        borderRadius: BorderRadius.circular(99),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'LOREBOOK',
                    style: TextStyle(
                      color: Glass.textPrimary,
                      fontSize: 12,
                      letterSpacing: 1.6,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    scan == null
                        ? 'This card has no lorebook.'
                        : '${scan.activated.length} active  ·  '
                            '${scan.tokenCost} tok'
                            '${scan.excludedByBudget.isEmpty ? '' : '  ·  ${scan.excludedByBudget.length} over budget'}',
                    style: const TextStyle(
                      color: Glass.textFaint,
                      fontSize: 11,
                    ),
                  ),
                  const SizedBox(height: 14),
                  if (scan != null && scan.activated.isEmpty)
                    const Text(
                      'Nothing activated yet. Keys are matched against the '
                      'conversation, so entries fire once something relevant is '
                      'said.',
                      style: TextStyle(
                        color: Glass.textFaint,
                        fontSize: 12,
                        height: 1.4,
                      ),
                    ),
                  for (final WorldInfoEntry entry
                      in scan?.activated ?? const <WorldInfoEntry>[])
                    _loreRow(entry),
                  if (prompt != null) ...<Widget>[
                    const SizedBox(height: 16),
                    const Text(
                      'LAST PROMPT',
                      style: TextStyle(
                        color: Glass.textPrimary,
                        fontSize: 12,
                        letterSpacing: 1.6,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '${prompt.messages.length} messages  ·  '
                      '${prompt.tokenCost} tok'
                      '${prompt.droppedForBudget.isEmpty ? '' : '  ·  ${prompt.droppedForBudget.length} trimmed'}',
                      style: const TextStyle(
                        color: Glass.textFaint,
                        fontSize: 11,
                      ),
                    ),
                    const SizedBox(height: 8),
                    for (final PromptBlock block in prompt.blocks)
                      _blockRow(block),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _loreRow(WorldInfoEntry entry) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Container(
            margin: const EdgeInsets.only(top: 5, right: 9),
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              color: Glass.tint(0.85),
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
                    fontSize: 12.5,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  '${entry.position.name}  ·  matched '
                  '${entry.keys.take(3).join(', ')}',
                  style: const TextStyle(
                    color: Glass.textFaint,
                    fontSize: 10.5,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _blockRow(PromptBlock block) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              block.id,
              style: const TextStyle(
                color: Glass.textSecondary,
                fontSize: 11,
              ),
            ),
          ),
          Text(
            '${block.tokenCost} tok',
            style: const TextStyle(color: Glass.textFaint, fontSize: 10.5),
          ),
        ],
      ),
    );
  }
}

/// Three pulsing dots, shown while waiting for the first token.
class _ThinkingDots extends StatefulWidget {
  const _ThinkingDots();

  @override
  State<_ThinkingDots> createState() => _ThinkingDotsState();
}

class _ThinkingDotsState extends State<_ThinkingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (BuildContext context, Widget? child) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            for (int i = 0; i < 3; i++) ...<Widget>[
              if (i > 0) const SizedBox(width: 5),
              Opacity(
                // Staggered, so the dots read as travelling light rather than a
                // single blink.
                opacity: 0.2 +
                    0.7 *
                        (1 -
                            (((_controller.value * 3) - i) % 3 - 1.5).abs() /
                                1.5),
                child: Container(
                  width: 6,
                  height: 6,
                  decoration: const BoxDecoration(
                    color: Glass.textPrimary,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

/// A circular glass button holding one icon, with an optional count badge.
class _IconAction extends StatelessWidget {
  const _IconAction({
    required this.icon,
    required this.onTap,
    this.badge,
    this.tooltip,
  });

  final IconData icon;
  final VoidCallback onTap;
  final String? badge;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    Widget button = GlassPanel(
      radius: 999,
      blur: 12,
      padding: const EdgeInsets.all(9),
      tintStrength: 1.3,
      shadow: false,
      showSpecular: false,
      child: Icon(icon, size: 16, color: Glass.textPrimary),
    );

    if (tooltip != null) {
      button = Tooltip(message: tooltip!, child: button);
    }

    if (badge == null) {
      return GestureDetector(onTap: onTap, child: button);
    }

    return GestureDetector(
      onTap: onTap,
      child: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          button,
          Positioned(
            right: -4,
            top: -5,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
              decoration: BoxDecoration(
                color: Glass.tint(0.92),
                borderRadius: BorderRadius.circular(99),
              ),
              child: Text(
                badge!,
                style: const TextStyle(
                  color: Color.fromRGBO(30, 18, 12, 1),
                  fontSize: 9,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
