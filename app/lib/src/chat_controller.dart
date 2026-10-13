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

  /// What the lorebook did on the most recent turn.
  WorldInfoScanResult? get scan => _scan;

  /// The exact prompt sent on the most recent turn, for the inspector.
  AssembledPrompt? get lastPrompt => _lastPrompt;

  /// Text of the reply currently arriving.
  String get streamingText => _streamingText;

  bool get isStreaming => _isStreaming;

  /// A user-facing failure from the last turn, or null.
  String? get error => _error;

  /// Clears the chat and re-seeds it with the card's opening greeting.
  void reset() {
    _history
      ..clear()
      ..add(
        ChatMessage(
          role: ChatRole.assistant,
          content: card.greetings.isEmpty
              ? '*They are here, and say nothing yet.*'
              : card.greetings.first,
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
    notifyListeners();
  }

  /// Swaps in a different opening greeting.
  void useGreeting(int index) {
    final List<String> greetings = card.greetings;
    if (index < 0 || index >= greetings.length || _history.isEmpty) return;
    _history[0] = ChatMessage(
      role: ChatRole.assistant,
      content: greetings[index],
    );
    _scan = _runScan();
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

    _history.add(ChatMessage(role: ChatRole.user, content: trimmed));
    _scan = _runScan();
    _error = null;
    notifyListeners();

    if (!settings.isConfigured) {
      // Not a failure state: a fresh install is simply unconfigured, and saying
      // so where the reply would appear beats a silent no-op.
      _error =
          'No backend configured. ${settings.configurationProblem} '
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

    final ChatBackend backend = _backendFactory(settings);
    final Completer<void> turn = Completer<void>();

    _activeBackend = backend;
    _turn = turn;
    _cancelled = false;
    _isStreaming = true;
    _streamingText = '';
    notifyListeners();

    _subscription = backend
        .stream(request)
        .listen(
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
              _error = error is BackendException
                  ? error.friendlyMessage
                  : 'Request failed: $error';
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

    if (!_cancelled) {
      final String reply = _streamingText.trim();
      if (reply.isEmpty) {
        _error ??= 'The provider returned an empty reply.';
      } else {
        _history.add(ChatMessage(role: ChatRole.assistant, content: reply));
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

    final String partial = _streamingText.trim();
    if (partial.isNotEmpty) {
      _history.add(ChatMessage(role: ChatRole.assistant, content: partial));
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

  ChatRequest _buildRequest() {
    final AssembledPrompt prompt = const PromptAssembler().assemble(
      card: card,
      userName: settings.personaName,
      personaDescription: settings.personaDescription,
      history: _history,
      lore: _scan,
      authorNote: settings.authorNote.trim().isEmpty
          ? null
          : settings.authorNote,
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
