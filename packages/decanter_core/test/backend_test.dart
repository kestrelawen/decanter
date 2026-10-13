import 'dart:convert';

import 'package:decanter_core/decanter_core.dart';
import 'package:test/test.dart';

/// A transport that replays canned SSE lines, so the streaming parser is
/// exercised without a network.
class FakeTransport implements HttpTransport {
  FakeTransport({this.statusCode = 200, List<String>? lines})
      : lines = lines ?? const <String>[];

  final int statusCode;
  final List<String> lines;

  Uri? lastUrl;
  Map<String, String>? lastHeaders;
  String? lastBody;
  int calls = 0;
  bool closed = false;

  @override
  Future<StreamedResponse> send({
    required String method,
    required Uri url,
    Map<String, String> headers = const <String, String>{},
    String? body,
  }) async {
    calls++;
    lastUrl = url;
    lastHeaders = headers;
    lastBody = body;
    return StreamedResponse(
      statusCode: statusCode,
      lines: Stream<String>.fromIterable(lines),
    );
  }

  @override
  void close() => closed = true;
}

/// Builds one well-formed OpenAI-style SSE delta line.
String sse(String content, {String? finishReason}) =>
    'data: ${jsonEncode(<String, dynamic>{
          'id': 'chatcmpl-test',
          'object': 'chat.completion.chunk',
          'choices': <dynamic>[
            <String, dynamic>{
              'index': 0,
              'delta': <String, dynamic>{'content': content},
              'finish_reason': finishReason,
            },
          ],
        })}';

OpenAiCompatibleBackend backendWith(
  FakeTransport transport, {
  String baseUrl = 'https://api.example.com/v1',
  String apiKey = 'sk-test',
}) =>
    OpenAiCompatibleBackend(
      baseUrl: baseUrl,
      apiKey: apiKey,
      transport: transport,
    );

ChatRequest requestWith({
  String model = 'test-model',
  List<ChatMessage>? messages,
  bool stream = true,
  double? temperature,
  int? maxTokens,
}) =>
    ChatRequest(
      model: model,
      stream: stream,
      temperature: temperature,
      maxTokens: maxTokens,
      messages: messages ??
          <ChatMessage>[
            const ChatMessage(
                role: ChatRole.system, content: 'You are a test.'),
            const ChatMessage(role: ChatRole.user, content: 'Hello'),
          ],
    );

void main() {
  group('streaming', () {
    test('emits deltas in order and terminates', () async {
      final transport = FakeTransport(
        lines: <String>[sse('Hel'), sse('lo'), 'data: [DONE]'],
      );
      final chunks =
          await backendWith(transport).stream(requestWith()).toList();

      expect(chunks.map((ChatChunk c) => c.delta).join(), 'Hello');
      expect(chunks.last.done, isTrue);
      expect(transport.calls, 1);
    });

    test('a provider that never sends [DONE] still terminates', () async {
      // Socket close without the sentinel is common; hanging here would leave
      // the UI stuck mid-reply forever.
      final transport = FakeTransport(lines: <String>[sse('All done')]);
      final chunks =
          await backendWith(transport).stream(requestWith()).toList();

      expect(chunks.map((ChatChunk c) => c.delta).join(), 'All done');
      expect(chunks.last.done, isTrue);
    });

    test('ignores comments, blanks and non-data lines', () async {
      final transport = FakeTransport(
        lines: <String>[
          ': keep-alive',
          '',
          'event: message',
          'id: 42',
          sse('real'),
          'data: [DONE]',
        ],
      );
      final chunks =
          await backendWith(transport).stream(requestWith()).toList();
      expect(chunks.map((ChatChunk c) => c.delta).join(), 'real');
    });

    test('skips malformed JSON rather than discarding the reply', () async {
      final transport = FakeTransport(
        lines: <String>[
          sse('keep'),
          'data: {not json at all',
          sse(' this'),
          'data: [DONE]',
        ],
      );
      final chunks =
          await backendWith(transport).stream(requestWith()).toList();
      expect(chunks.map((ChatChunk c) => c.delta).join(), 'keep this');
    });

    test('a finish_reason chunk with no content completes the stream',
        () async {
      final transport = FakeTransport(
        lines: <String>[
          sse('text'),
          'data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}',
        ],
      );
      final chunks =
          await backendWith(transport).stream(requestWith()).toList();
      expect(chunks.map((ChatChunk c) => c.delta).join(), 'text');
      expect(chunks.last.done, isTrue);
    });

    test('a role-only first chunk yields nothing but does not break', () async {
      final transport = FakeTransport(
        lines: <String>[
          'data: {"choices":[{"index":0,"delta":{"role":"assistant"}}]}',
          sse('hi'),
          'data: [DONE]',
        ],
      );
      final chunks =
          await backendWith(transport).stream(requestWith()).toList();
      expect(chunks.map((ChatChunk c) => c.delta).join(), 'hi');
    });

    test('complete() gathers the whole reply', () async {
      final transport = FakeTransport(
        lines: <String>[sse('one '), sse('two '), sse('three'), 'data: [DONE]'],
      );
      final text = await backendWith(transport).complete(requestWith());
      expect(text, 'one two three');
    });
  });

  group('request shape', () {
    test('sends model, stream and ordered messages', () async {
      final transport = FakeTransport(lines: <String>['data: [DONE]']);
      await backendWith(transport).stream(requestWith()).toList();

      final body = jsonDecode(transport.lastBody!) as Map<String, dynamic>;
      expect(body['model'], 'test-model');
      expect(body['stream'], isTrue);
      final messages = body['messages'] as List<dynamic>;
      expect(messages, hasLength(2));
      expect((messages[0] as Map)['role'], 'system');
      expect((messages[1] as Map)['content'], 'Hello');
    });

    test('omits sampling parameters the caller did not set', () async {
      // Sending them as null or zero would pin server defaults the user never
      // chose.
      final transport = FakeTransport(lines: <String>['data: [DONE]']);
      await backendWith(transport).stream(requestWith()).toList();

      final body = jsonDecode(transport.lastBody!) as Map<String, dynamic>;
      expect(body.containsKey('temperature'), isFalse);
      expect(body.containsKey('max_tokens'), isFalse);
      expect(body.containsKey('top_p'), isFalse);
    });

    test('including the ones that were set', () async {
      final transport = FakeTransport(lines: <String>['data: [DONE]']);
      await backendWith(
        transport,
      ).stream(requestWith(temperature: 0.8, maxTokens: 256)).toList();

      final body = jsonDecode(transport.lastBody!) as Map<String, dynamic>;
      expect(body['temperature'], 0.8);
      expect(body['max_tokens'], 256);
    });

    test('sends the bearer token', () async {
      final transport = FakeTransport(lines: <String>['data: [DONE]']);
      await backendWith(transport, apiKey: 'sk-secret')
          .stream(requestWith())
          .toList();
      expect(transport.lastHeaders!['Authorization'], 'Bearer sk-secret');
    });

    test('accepts a stream event-stream when streaming', () async {
      final transport = FakeTransport(lines: <String>['data: [DONE]']);
      await backendWith(transport).stream(requestWith()).toList();
      expect(transport.lastHeaders!['Accept'], 'text/event-stream');
    });
  });

  group('base URL normalisation', () {
    test('four spellings of the same endpoint converge', () {
      const String expected = 'https://api.openai.com/v1';
      expect(
          OpenAiCompatibleBackend.normalizeBaseUrl('https://api.openai.com/v1'),
          expected);
      expect(
          OpenAiCompatibleBackend.normalizeBaseUrl(
              'https://api.openai.com/v1/'),
          expected);
      expect(
          OpenAiCompatibleBackend.normalizeBaseUrl(
              '  https://api.openai.com/v1/  '),
          expected);
      expect(
        OpenAiCompatibleBackend.normalizeBaseUrl(
            'https://api.openai.com/v1/chat/completions'),
        expected,
      );
    });

    test('an empty base URL stays empty rather than throwing', () {
      expect(OpenAiCompatibleBackend.normalizeBaseUrl(''), '');
      expect(OpenAiCompatibleBackend.normalizeBaseUrl('   '), '');
    });

    test('the request goes to /chat/completions under the base', () async {
      final transport = FakeTransport(lines: <String>['data: [DONE]']);
      await backendWith(
        transport,
        baseUrl: 'https://api.example.com/v1/',
      ).stream(requestWith()).toList();
      expect(
        transport.lastUrl.toString(),
        'https://api.example.com/v1/chat/completions',
      );
    });
  });

  group('errors', () {
    test('401 reports a rejected key', () async {
      final transport = FakeTransport(
        statusCode: 401,
        lines: <String>['{"error":{"message":"Invalid API key"}}'],
      );
      expect(
        () => backendWith(transport).stream(requestWith()).toList(),
        throwsA(
          isA<BackendException>()
              .having((BackendException e) => e.statusCode, 'status', 401)
              .having(
                (BackendException e) => e.friendlyMessage,
                'friendly',
                contains('API key was rejected'),
              ),
        ),
      );
    });

    test('extracts the provider message from an error body', () async {
      final transport = FakeTransport(
        statusCode: 400,
        lines: <String>['{"error":{"message":"model `nope` does not exist"}}'],
      );
      try {
        await backendWith(transport).stream(requestWith()).toList();
        fail('expected a BackendException');
      } on BackendException catch (e) {
        expect(e.message, contains('does not exist'));
        expect(e.statusCode, 400);
      }
    });

    test('404 points at the base URL and model', () async {
      final transport =
          FakeTransport(statusCode: 404, lines: <String>['not found']);
      try {
        await backendWith(transport).stream(requestWith()).toList();
        fail('expected a BackendException');
      } on BackendException catch (e) {
        expect(e.friendlyMessage, contains('base URL'));
      }
    });

    test('429 points at quota', () async {
      final transport =
          FakeTransport(statusCode: 429, lines: <String>['slow down']);
      try {
        await backendWith(transport).stream(requestWith()).toList();
        fail('expected a BackendException');
      } on BackendException catch (e) {
        expect(e.friendlyMessage, contains('Rate limited'));
      }
    });

    test('500 is attributed to the provider', () async {
      final transport =
          FakeTransport(statusCode: 503, lines: <String>['upstream down']);
      try {
        await backendWith(transport).stream(requestWith()).toList();
        fail('expected a BackendException');
      } on BackendException catch (e) {
        expect(e.friendlyMessage, contains('their side'));
      }
    });

    test('a non-JSON error body is still reported', () async {
      final transport = FakeTransport(
        statusCode: 502,
        lines: <String>['<html>bad gateway</html>'],
      );
      try {
        await backendWith(transport).stream(requestWith()).toList();
        fail('expected a BackendException');
      } on BackendException catch (e) {
        expect(e.message, contains('bad gateway'));
      }
    });
  });

  group('non-streaming', () {
    test('parses choices[0].message.content', () async {
      final transport = FakeTransport(
        lines: <String>[
          '{"choices":[{"index":0,"message":{"role":"assistant","content":"Hi there"},'
              '"finish_reason":"stop"}]}',
        ],
      );
      final chunks = await backendWith(
        transport,
      ).stream(requestWith(stream: false)).toList();

      expect(chunks, hasLength(1));
      expect(chunks.single.delta, 'Hi there');
      expect(chunks.single.done, isTrue);
      expect(transport.lastHeaders!['Accept'], 'application/json');
    });

    test('an empty choices array yields a terminal chunk, not a crash',
        () async {
      final transport = FakeTransport(lines: <String>['{"choices":[]}']);
      final chunks = await backendWith(
        transport,
      ).stream(requestWith(stream: false)).toList();
      expect(chunks.single.done, isTrue);
      expect(chunks.single.delta, isEmpty);
    });

    test('a non-JSON body is an error', () async {
      final transport = FakeTransport(lines: <String>['<html>nope</html>']);
      expect(
        () =>
            backendWith(transport).stream(requestWith(stream: false)).toList(),
        throwsA(isA<BackendException>()),
      );
    });
  });

  group('lifecycle', () {
    test('close() closes the transport', () async {
      final transport = FakeTransport();
      await backendWith(transport).close();
      expect(transport.closed, isTrue);
    });
  });
}
