import 'dart:async';
import 'dart:convert';

import 'chat.dart';

/// A request to a chat backend.
///
/// Sampling parameters are nullable so an absent value sends no field at all —
/// letting the server's own defaults apply instead of pinning something the
/// user never chose.
class ChatRequest {
  const ChatRequest({
    required this.model,
    required this.messages,
    this.temperature,
    this.topP,
    this.maxTokens,
    this.frequencyPenalty,
    this.presencePenalty,
    this.stop,
    this.stream = true,
    this.extra = const <String, dynamic>{},
  });

  final String model;
  final List<ChatMessage> messages;
  final double? temperature;
  final double? topP;
  final int? maxTokens;
  final double? frequencyPenalty;
  final double? presencePenalty;
  final List<String>? stop;
  final bool stream;

  /// Provider-specific passthrough, merged last.
  final Map<String, dynamic> extra;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'model': model,
        'stream': stream,
        'messages': <Map<String, dynamic>>[
          for (final ChatMessage m in messages)
            <String, dynamic>{
              'role': m.role.name,
              if (m.name != null && m.name!.isNotEmpty) 'name': m.name,
              'content': m.content,
            },
        ],
        if (temperature != null) 'temperature': temperature,
        if (topP != null) 'top_p': topP,
        if (maxTokens != null) 'max_tokens': maxTokens,
        if (frequencyPenalty != null) 'frequency_penalty': frequencyPenalty,
        if (presencePenalty != null) 'presence_penalty': presencePenalty,
        if (stop != null && stop!.isNotEmpty) 'stop': stop,
        ...extra,
      };
}

/// One increment of a streamed reply.
class ChatChunk {
  const ChatChunk({this.delta = '', this.finishReason, this.done = false});

  /// Text added by this chunk. May be empty on a role-only or keep-alive chunk.
  final String delta;

  final String? finishReason;

  /// True on the terminal chunk.
  final bool done;

  bool get isEmpty => delta.isEmpty;

  @override
  String toString() => 'ChatChunk(${delta.length} chars${done ? ", done" : ""}'
      '${finishReason == null ? "" : ", $finishReason"})';
}

abstract class ChatBackend {
  /// Streams a reply. Emits [ChatChunk]s and closes after a terminal chunk.
  Stream<ChatChunk> stream(ChatRequest request);

  Future<void> close();
}

/// Convenience helpers for any [ChatBackend].
///
/// An extension rather than a concrete method on the interface: `implements`
/// does not inherit implementations, so a method declared there would force
/// every backend to restate it.
extension ChatBackendComplete on ChatBackend {
  /// Gathers a streamed reply into one string.
  Future<String> complete(ChatRequest request) async {
    final buffer = StringBuffer();
    await for (final ChatChunk chunk in stream(request)) {
      buffer.write(chunk.delta);
    }
    return buffer.toString();
  }
}

/// A failure from the backend, carrying enough to show a user something useful.
class BackendException implements Exception {
  BackendException({
    required this.message,
    this.statusCode,
    this.body,
  });

  final String message;
  final int? statusCode;
  final String? body;

  /// A short, human-readable cause. The distinction that matters to a user is
  /// "your key is wrong" versus "the server is unhappy" versus "the network
  /// died" — everything else is detail.
  String get friendlyMessage {
    if (statusCode == 401 || statusCode == 403) {
      return 'The API key was rejected (HTTP $statusCode). Check the key and '
          'that it is valid for this endpoint.';
    }
    if (statusCode == 404) {
      return 'Endpoint or model not found (HTTP 404). Check the base URL and '
          'the model name.';
    }
    if (statusCode == 429) {
      return 'Rate limited or out of quota (HTTP 429). Wait and retry, or '
          'check your account balance.';
    }
    if (statusCode != null && statusCode! >= 500) {
      return 'The provider returned a server error (HTTP $statusCode). '
          'This is on their side — retrying may work.';
    }
    return message;
  }

  @override
  String toString() =>
      'BackendException(${statusCode == null ? "" : "HTTP $statusCode: "}$message)';
}

/// One line-oriented HTTP response.
class StreamedResponse {
  const StreamedResponse({required this.statusCode, required this.lines});

  final int statusCode;

  /// Body decoded as UTF-8 and split into lines, streamed.
  final Stream<String> lines;

  /// Reads the whole body back as a string.
  static Future<String> collect(Stream<String> lines) async {
    final buffer = StringBuffer();
    await for (final String line in lines) {
      buffer.writeln(line);
    }
    return buffer.toString();
  }
}

/// The HTTP seam.
///
/// An interface rather than a raw `HttpClient` so the streaming parser can be
/// tested exhaustively without a network — which is the only way this logic gets
/// verified on a machine with no emulator.
abstract class HttpTransport {
  Future<StreamedResponse> send({
    required String method,
    required Uri url,
    Map<String, String> headers = const <String, String>{},
    String? body,
  });

  void close();
}

/// Talks to any OpenAI-compatible `/chat/completions` endpoint.
///
/// Covers the whole BYOK field: OpenAI, OpenRouter, DeepSeek, Groq, Together,
/// llama.cpp, Ollama, LM Studio, vLLM and anything else that speaks the same
/// request and SSE shape.
class OpenAiCompatibleBackend implements ChatBackend {
  OpenAiCompatibleBackend({
    required String baseUrl,
    required this.apiKey,
    required this.transport,
    Map<String, String> extraHeaders = const <String, String>{},
  })  : baseUrl = normalizeBaseUrl(baseUrl),
        _extraHeaders = extraHeaders;

  /// Where the API lives, without a trailing slash and without
  /// `/chat/completions`.
  final String baseUrl;

  final String apiKey;
  final HttpTransport transport;
  final Map<String, String> _extraHeaders;

  /// Accepts `https://api.openai.com`, `https://api.openai.com/`,
  /// `https://api.openai.com/v1` and `.../v1/chat/completions` and returns the
  /// same base every time, because users paste all four.
  static String normalizeBaseUrl(String raw) {
    var url = raw.trim();
    if (url.isEmpty) return '';
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    for (final String suffix in <String>['/chat/completions', '/completions']) {
      if (url.endsWith(suffix)) {
        url = url.substring(0, url.length - suffix.length);
      }
    }
    return url;
  }

  Uri get endpoint => Uri.parse('$baseUrl/chat/completions');

  @override
  Stream<ChatChunk> stream(ChatRequest request) async* {
    final StreamedResponse response = await transport.send(
      method: 'POST',
      url: endpoint,
      headers: <String, String>{
        'Content-Type': 'application/json',
        'Accept': request.stream ? 'text/event-stream' : 'application/json',
        'Authorization': 'Bearer $apiKey',
        ..._extraHeaders,
      },
      body: jsonEncode(request.toJson()),
    );

    if (response.statusCode != 200) {
      // The error body is where providers explain themselves; surface it in the
      // log but summarise it for the user.
      final String body = await StreamedResponse.collect(response.lines);
      String detail = body.trim();
      try {
        final Object? decoded = jsonDecode(body);
        if (decoded is Map) {
          final Object? error = decoded['error'];
          if (error is Map && error['message'] is String) {
            detail = error['message'] as String;
          } else if (decoded['message'] is String) {
            detail = decoded['message'] as String;
          }
        }
      } on FormatException {
        // Not JSON. Keep the raw text.
      }
      throw BackendException(
        message: detail.isEmpty ? 'Request failed' : detail,
        statusCode: response.statusCode,
        body: body,
      );
    }

    if (!request.stream) {
      yield _parseWholeResponse(await StreamedResponse.collect(response.lines));
      return;
    }

    await for (final ChatChunk chunk in _parseSse(response.lines)) {
      yield chunk;
    }
  }

  /// Parses an SSE body into chunks.
  ///
  /// Tolerant by design: comments, blank lines, unrecognised event types and
  /// malformed JSON are skipped rather than thrown, because a mid-stream parse
  /// error would otherwise discard a reply the user can already see.
  Stream<ChatChunk> _parseSse(Stream<String> lines) async* {
    var sawTerminator = false;

    await for (final String rawLine in lines) {
      final String line = rawLine.trimRight();
      if (line.isEmpty) continue;
      if (line.startsWith(':')) continue; // SSE comment / keep-alive

      if (!line.startsWith('data:')) {
        // `event:` and `id:` lines carry no content for this API shape.
        continue;
      }

      final String payload = line.substring(5).trim();
      if (payload.isEmpty) continue;

      if (payload == '[DONE]') {
        sawTerminator = true;
        yield const ChatChunk(done: true);
        break;
      }

      final Map<String, dynamic>? json = _tryDecode(payload);
      if (json == null) continue;

      final ChatChunk? chunk = _chunkFrom(json);
      if (chunk != null) yield chunk;
    }

    // Some providers close the socket without sending [DONE]. Emitting the
    // terminal chunk anyway keeps callers from hanging on a finished stream.
    if (!sawTerminator) yield const ChatChunk(done: true);
  }

  ChatChunk _parseWholeResponse(String body) {
    final Map<String, dynamic>? json = _tryDecode(body);
    if (json == null) {
      throw BackendException(
        message: 'Response was not valid JSON',
        body: body,
      );
    }
    final Object? choices = json['choices'];
    if (choices is List && choices.isNotEmpty) {
      final Object? first = choices.first;
      if (first is Map) {
        final Object? message = first['message'];
        if (message is Map && message['content'] is String) {
          return ChatChunk(
            delta: message['content'] as String,
            finishReason: first['finish_reason'] as String?,
            done: true,
          );
        }
        if (first['text'] is String) {
          return ChatChunk(
            delta: first['text'] as String,
            finishReason: first['finish_reason'] as String?,
            done: true,
          );
        }
      }
    }
    return const ChatChunk(done: true);
  }

  ChatChunk? _chunkFrom(Map<String, dynamic> json) {
    final Object? choices = json['choices'];
    if (choices is! List || choices.isEmpty) return null;

    final Object? first = choices.first;
    if (first is! Map) return null;

    final String? finishReason = first['finish_reason'] as String?;
    final Object? delta = first['delta'];

    // A chunk may carry only a finish_reason, with no content at all.
    if (delta is! Map) {
      return finishReason == null
          ? null
          : ChatChunk(finishReason: finishReason, done: true);
    }

    final Object? content = delta['content'];
    final String text = content is String ? content : '';

    // `reasoning_content` is a separate field on some providers and is
    // deliberately not surfaced as reply text.
    return ChatChunk(
      delta: text,
      finishReason: finishReason,
      done: finishReason != null,
    );
  }

  Map<String, dynamic>? _tryDecode(String payload) {
    try {
      final Object? decoded = jsonDecode(payload);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
    } on FormatException {
      return null;
    }
  }

  @override
  Future<void> close() async => transport.close();
}
