import 'dart:async';

import 'package:decanter_core/decanter_core.dart';
import 'package:flutter/foundation.dart';

import 'settings.dart';

/// Builds a backend for the current settings. Injectable so tests can supply a
/// fake instead of reaching the network.
typedef BackendFactory = ChatBackend Function(AppSettings settings);

/// Owns one chat: its history, its lorebook timing, and the in-flight reply.
///
/// A `ChangeNotifier` rather than a state-management package, because there is
/// exactly one consumer (the screen) and a dependency that renders widgets would
/// be weight without benefit.
class ChatController extends ChangeNotifier {
  ChatController({
    required this.card,
    required this.settings,
    BackendFactory? backendFactory,
  }) : _backendFactory = backendFactory ?? _defaultBackend {
    reset();
  }

  final TavernCard card;
  AppSettings settings;

  final BackendFactory _backendFactory;

  static ChatBackend _defaultBackend(AppSettings settings) =>
      OpenAiCompatibleBackend(
        baseUrl: settings.baseUrl,
        apiKey: settings.apiKey,
        transport: IoHttpTransport(),
      );

  final List<ChatMessage> _history = <ChatMessage>[];
  final WorldInfoTiming _timing = WorldInfoTiming();

  WorldInfoScanResult? _scan;
  AssembledPrompt? _lastPrompt;
  String _streamingText = '';
  bool _isStreaming = false;
  String? _error;
  int? _regeneratingIndex;
  int? _continuingIndex;
  int _revision = 0;

  /// Held explicitly rather than consumed with `await for`, so [stop] can cancel
  /// the request the moment it is called. An `await for` loop only notices a
  /// cancellation flag when the *next* chunk arrives — against a provider that
  /// has gone quiet, that never happens, and the request would be left open.
  StreamSubscription<ChatChunk>? _subscription;
  ChatBackend? _activeBackend;
  Completer<void>? _turn;
  bool _cancelled = false;

  /// The conversation, oldest first. Includes the opening greeting.
  List<ChatMessage> get history => List<ChatMessage>.unmodifiable(_history);

  /// Incremented whenever history changes, so persistence can detect settled edits.
  int get revision => _revision;

  /// What the lorebook did on the most recent turn.
  WorldInfoScanResult? get scan => _scan;

  /// The exact prompt sent on the most recent turn, for the inspector.
  AssembledPrompt? get lastPrompt => _lastPrompt;

  /// Text of the reply currently arriving.
  String get streamingText => _streamingText;

  bool get isStreaming => _isStreaming;

  /// Index of the message being regenerated, or null during normal turns.
  int? get regeneratingIndex => _regeneratingIndex;

  /// Index of the message being extended with continue, or null.
  int? get continuingIndex => _continuingIndex;

  bool get isContinuing => _continuingIndex != null;

  /// A user-facing failure from the last turn, or null.
  String? get error => _error;

  /// Clears the chat and re-seeds it with the card's opening greeting.
  void reset() {
    final List<String> greetings = card.greetings.isEmpty
        ? const <String>['*They are here, and say nothing yet.*']
        : card.greetings;

    _history
      ..clear()
      ..add(
        ChatMessage(
          role: ChatRole.assistant,
          content: greetings.first,
          swipes: List<String>.from(greetings),
          swipeIndex: 0,
        ),
      );

    // Cooldowns and sticky windows are per-chat; carrying them through a reset
    // would fire lore in a fresh conversation for no visible reason.
    for (final EntryTiming entry in _timing.entries.values) {
      entry.stickyLeft = 0;
      entry.cooldownLeft = 0;
      entry.delayLeft = 0;
    }

    _scan = _runScan();
    _lastPrompt = null;
    _streamingText = '';
    _isStreaming = false;
    _cancelled = false;
    _error = null;
    _regeneratingIndex = null;
    _continuingIndex = null;
    _revision++;
    notifyListeners();
  }

  /// Replaces the conversation wholesale, e.g. when restoring it from disk.
  ///
  /// The lorebook scan is re-run rather than carried over: knowing which lore is
  /// active is a function of the history, and stale timing from another session
  /// would fire entries for no visible reason.
  void replaceHistory(List<ChatMessage> messages) {
    if (messages.isEmpty) return;
    _history
      ..clear()
      ..addAll(
        messages.map((ChatMessage m) {
          if (m.swipes.isEmpty && m.content.isNotEmpty) {
            return m.copyWith(swipes: <String>[m.content], swipeIndex: 0);
          }
          return m;
        }),
      );
    _scan = _runScan();
    _error = null;
    _revision++;
    notifyListeners();
  }

  /// Swaps in a different opening greeting.
  void useGreeting(int index) {
    if (_history.isEmpty) return;
    final List<String> greetings = card.greetings;
    if (index < 0 || index >= greetings.length) return;

    final ChatMessage first = _history[0];
    final int existingIndex = first.swipes.indexOf(greetings[index]);
    if (existingIndex != -1) {
      setSwipe(0, existingIndex);
    } else {
      _history[0] = first.withAddedSwipe(greetings[index]);
      _scan = _runScan();
      _revision++;
      notifyListeners();
    }
  }

  /// Selects a specific swipe index for a message in history.
  void setSwipe(int messageIndex, int swipeIndex) {
    if (messageIndex < 0 || messageIndex >= _history.length) return;
    final ChatMessage message = _history[messageIndex];
    if (swipeIndex < 0 || swipeIndex >= message.swipes.length) return;
    if (message.swipeIndex == swipeIndex) return;

    _history[messageIndex] = message.withSwipeIndex(swipeIndex);
    _scan = _runScan();
    _revision++;
    notifyListeners();
  }

  /// Navigates to the previous swipe for a message.
  void previousSwipe(int messageIndex) {
    if (messageIndex < 0 || messageIndex >= _history.length) return;
    final ChatMessage message = _history[messageIndex];
    if (message.canSwipeLeft) {
      setSwipe(messageIndex, message.swipeIndex - 1);
    }
  }

  /// Navigates to the next swipe for a message.
  void nextSwipe(int messageIndex) {
    if (messageIndex < 0 || messageIndex >= _history.length) return;
    final ChatMessage message = _history[messageIndex];
    if (message.canSwipeRight) {
      setSwipe(messageIndex, message.swipeIndex + 1);
    }
  }

  /// Deletes a specific swipe from a message.
  void deleteSwipe(int messageIndex, int swipeIndex) {
    if (messageIndex < 0 || messageIndex >= _history.length) return;
    final ChatMessage message = _history[messageIndex];
    if (message.swipes.length <= 1) return;

    _history[messageIndex] = message.withDeletedSwipe(swipeIndex);
    _scan = _runScan();
    _revision++;
    notifyListeners();
  }

  /// Edits the active text of an existing message in history.
  void editMessage(int index, String newContent) {
    if (index < 0 || index >= _history.length) return;
    final String trimmed = newContent.trim();
    if (trimmed.isEmpty) return;

    _history[index] = _history[index].withEditedContent(trimmed);
    _scan = _runScan();
    _revision++;
    notifyListeners();
  }

  /// Removes an individual message from history.
  void deleteMessage(int index) {
    if (index < 0 || index >= _history.length) return;
    if (_history.length <= 1) {
      reset();
      return;
    }

    _history.removeAt(index);
    _scan = _runScan();
    _revision++;
    notifyListeners();
  }

  /// Prunes conversation history starting at [index] down to the end.
  void pruneFrom(int index) {
    if (index < 0 || index >= _history.length) return;
    if (index == 0) {
      reset();
      return;
    }

    _history.removeRange(index, _history.length);
    _scan = _runScan();
    _revision++;
    notifyListeners();
  }

  /// Injects a system/narrator note into history without triggering a generation.
  void addNarratorNote(String note) {
    final String trimmed = note.trim();
    if (trimmed.isEmpty) return;

    _history.add(
      ChatMessage(
        role: ChatRole.system,
        content: trimmed,
        isSystemNote: true,
      ),
    );
    _scan = _runScan();
    _revision++;
    notifyListeners();
  }

  /// Swaps in new settings without disturbing the conversation.
  void updateSettings(AppSettings next) {
    settings = next;
    notifyListeners();
  }

  /// Sends a message and streams the reply into [streamingText].
  ///
  /// Completes when the turn ends — whether that is the provider finishing, an
  /// error, or [stop].
  Future<void> send(String text) async {
    final String trimmed = text.trim();
    if (trimmed.isEmpty || _isStreaming) return;

    _history.add(
      ChatMessage(
        role: ChatRole.user,
        content: trimmed,
        swipes: <String>[trimmed],
        swipeIndex: 0,
      ),
    );
    _scan = _runScan();
    _error = null;
    _revision++;
    notifyListeners();

    if (!settings.isConfigured) {
      // Not a failure state: a fresh install is simply unconfigured, and saying
      // so where the reply would appear beats a silent no-op.
      _error = 'No backend configured. ${settings.configurationProblem} '
          'Open settings to add one.';
      notifyListeners();
      return;
    }

    final ChatRequest request;
    try {
      request = _buildRequest();
    } on Object catch (error) {
      _error = 'Could not assemble the prompt: $error';
      notifyListeners();
      return;
    }

    return _executeTurn(request, regeneratingIndex: null);
  }

  /// Generates an alternative swipe for an assistant message.
  ///
  /// Defaults to the last assistant message in history.
  Future<void> regenerate({int? messageIndex}) async {
    if (_history.isEmpty || _isStreaming) return;

    final int targetIndex = messageIndex ??
        _history.lastIndexWhere(
          (ChatMessage m) => m.role == ChatRole.assistant,
        );
    if (targetIndex < 0 ||
        targetIndex >= _history.length ||
        _history[targetIndex].role != ChatRole.assistant) {
      return;
    }

    if (!settings.isConfigured) {
      _error = 'No backend configured. ${settings.configurationProblem} '
          'Open settings to add one.';
      notifyListeners();
      return;
    }

    final List<ChatMessage> historyForPrompt = _history.sublist(0, targetIndex);
    final ChatRequest request;
    try {
      request = _buildRequest(historyOverride: historyForPrompt);
    } on Object catch (error) {
      _error = 'Could not assemble the prompt: $error';
      notifyListeners();
      return;
    }

    return _executeTurn(request, regeneratingIndex: targetIndex);
  }

  /// Continues generating from the end of an assistant reply.
  Future<void> continueGeneration({int? messageIndex}) async {
    if (_history.isEmpty || _isStreaming) return;

    final int targetIndex = messageIndex ??
        _history.lastIndexWhere(
          (ChatMessage m) => m.role == ChatRole.assistant,
        );
    if (targetIndex < 0 ||
        targetIndex >= _history.length ||
        _history[targetIndex].role != ChatRole.assistant) {
      return;
    }

    if (!settings.isConfigured) {
      _error = 'No backend configured. ${settings.configurationProblem} '
          'Open settings to add one.';
      notifyListeners();
      return;
    }

    final List<ChatMessage> historyForPrompt = <ChatMessage>[
      ..._history.sublist(0, targetIndex + 1),
      const ChatMessage(
        role: ChatRole.user,
        content:
            '[Continue your previous response from where you left off. Do not repeat any words already written; begin immediately with the next word.]',
        isSystemNote: true,
      ),
    ];

    final ChatRequest request;
    try {
      request = _buildRequest(historyOverride: historyForPrompt);
    } on Object catch (error) {
      _error = 'Could not assemble the prompt: $error';
      notifyListeners();
      return;
    }

    return _executeTurn(
      request,
      regeneratingIndex: null,
      continuingIndex: targetIndex,
    );
  }

  Future<void> _executeTurn(
    ChatRequest request, {
    required int? regeneratingIndex,
    int? continuingIndex,
  }) {
    final ChatBackend backend = _backendFactory(settings);
    final Completer<void> turn = Completer<void>();

    _activeBackend = backend;
    _turn = turn;
    _regeneratingIndex = regeneratingIndex;
    _continuingIndex = continuingIndex;
    _cancelled = false;
    _isStreaming = true;
    _streamingText = '';
    _error = null;
    notifyListeners();

    _subscription = backend.stream(request).listen(
      (ChatChunk chunk) {
        if (_cancelled) return;
        if (chunk.delta.isNotEmpty) {
          _streamingText += chunk.delta;
          notifyListeners();
        }
        if (chunk.done) _finishTurn();
      },
      onError: (Object error) {
        if (!_cancelled) {
          final String s = error.toString().toLowerCase();
          final bool isDroppedSocket =
              s.contains('connection closed while receiving data') ||
                  s.contains('connection closed before full header') ||
                  s.contains('connection reset') ||
                  s.contains('software caused connection abort') ||
                  s.contains('broken pipe');
          if (_streamingText.trim().isNotEmpty && isDroppedSocket) {
            _error = null;
          } else {
            _error = error is BackendException
                ? error.friendlyMessage
                : 'Request failed: $error';
          }
        }
        _finishTurn();
      },
      onDone: _finishTurn,
      cancelOnError: true,
    );

    return turn.future;
  }

  /// Settles the turn exactly once, whichever path reached it.
  void _finishTurn() {
    final Completer<void>? turn = _turn;
    if (turn == null || turn.isCompleted) return;
    _turn = null;

    final int? contIndex = _continuingIndex;
    _continuingIndex = null;
    final int? regenIndex = _regeneratingIndex;
    _regeneratingIndex = null;

    if (!_cancelled) {
      final String reply = _streamingText;
      if (reply.trim().isEmpty) {
        _error ??= 'The provider returned an empty reply.';
      } else {
        if (_error != null &&
            _error!.toLowerCase().contains('connection closed')) {
          _error = null;
        }
        if (contIndex != null && contIndex < _history.length) {
          final String base = _history[contIndex].content;
          final String toAppend = (base.isNotEmpty &&
                  !base.endsWith(' ') &&
                  !base.endsWith('\n') &&
                  !reply.startsWith(' ') &&
                  !reply.startsWith('\n'))
              ? ' $reply'
              : reply;
          _history[contIndex] =
              _history[contIndex].withAppendedContent(toAppend);
        } else if (regenIndex != null && regenIndex < _history.length) {
          _history[regenIndex] =
              _history[regenIndex].withAddedSwipe(reply.trim());
        } else {
          _history.add(
            ChatMessage(
              role: ChatRole.assistant,
              content: reply.trim(),
              swipes: <String>[reply.trim()],
              swipeIndex: 0,
            ),
          );
        }
        _revision++;
      }
    }

    _streamingText = '';
    _isStreaming = false;

    final ChatBackend? backend = _activeBackend;
    _activeBackend = null;
    // Closing the transport is fire-and-forget: the turn is already settled from
    // the caller's point of view.
    unawaited(backend?.close() ?? Future<void>.value());

    turn.complete();
    notifyListeners();
  }

  /// Abandons the in-flight reply, keeping whatever text already arrived.
  ///
  /// [stop] adds the partial reply itself, so [_finishTurn] must not add it
  /// again — hence the cancellation check there.
  void stop() {
    if (!_isStreaming) return;
    _cancelled = true;

    final int? contIndex = _continuingIndex;
    _continuingIndex = null;
    final int? regenIndex = _regeneratingIndex;
    _regeneratingIndex = null;

    final String partial = _streamingText;
    if (partial.trim().isNotEmpty) {
      if (contIndex != null && contIndex < _history.length) {
        final String base = _history[contIndex].content;
        final String toAppend = (base.isNotEmpty &&
                !base.endsWith(' ') &&
                !base.endsWith('\n') &&
                !partial.startsWith(' ') &&
                !partial.startsWith('\n'))
            ? ' $partial'
            : partial;
        _history[contIndex] = _history[contIndex].withAppendedContent(toAppend);
      } else if (regenIndex != null && regenIndex < _history.length) {
        _history[regenIndex] =
            _history[regenIndex].withAddedSwipe(partial.trim());
      } else {
        _history.add(
          ChatMessage(
            role: ChatRole.assistant,
            content: partial.trim(),
            swipes: <String>[partial.trim()],
            swipeIndex: 0,
          ),
        );
      }
      _revision++;
    }

    // Cancel first: this is what actually abandons the HTTP request.
    final StreamSubscription<ChatChunk>? subscription = _subscription;
    _subscription = null;
    unawaited(subscription?.cancel() ?? Future<void>.value());

    _finishTurn();
  }

  /// Drops the most recent exchange so it can be sent again.
  void removeLastExchange() {
    if (_history.length < 2) return;
    if (_history.last.role == ChatRole.assistant) _history.removeLast();
    if (_history.length > 1 && _history.last.role == ChatRole.user) {
      _history.removeLast();
    }
    _scan = _runScan();
    _error = null;
    _revision++;
    notifyListeners();
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel() ?? Future<void>.value());
    unawaited(_activeBackend?.close() ?? Future<void>.value());
    super.dispose();
  }

  WorldInfoScanResult _runScan() {
    final CharacterBook? book = card.characterBook;
    return WorldInfoScanner().scan(
      sources: book == null
          ? const <WorldInfoSource>[]
          : <WorldInfoSource>[WorldInfoSource(key: 'character', book: book)],
      history: _history,
      timing: _timing,
      tokenBudget: settings.contextBudget > 0 ? settings.contextBudget : 0,
    );
  }

  ChatRequest _buildRequest({List<ChatMessage>? historyOverride}) {
    final List<ChatMessage> historyToUse = historyOverride ?? _history;
    final AssembledPrompt prompt = const PromptAssembler().assemble(
      card: card,
      userName: settings.personaName,
      personaDescription: settings.personaDescription,
      history: historyToUse,
      lore: _scan,
      authorNote:
          settings.authorNote.trim().isEmpty ? null : settings.authorNote,
      contextBudget: settings.contextBudget,
    );
    _lastPrompt = prompt;

    return ChatRequest(
      model: settings.model,
      messages: prompt.messages,
      temperature: settings.temperature,
      maxTokens: settings.maxTokens,
      stream: true,
    );
  }
}
