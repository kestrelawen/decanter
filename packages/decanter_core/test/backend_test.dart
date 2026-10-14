import 'dart:async';
import 'dart:convert';

import 'package:decanter_core/decanter_core.dart';
import 'package:test/test.dart';

/// A transport that replays canned SSE lines, so the streaming parser is
/// exercised without a network.
class FakeTransport implements HttpTransport {
  FakeTransport({
    this.statusCode = 200,
    List<String>? lines,
    Stream<String>? stream,
  })  : lines = lines ?? const <String>[],
        _stream = stream;

  final int statusCode;
  final List<String> lines;
  final Stream<String>? _stream;

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
      lines: _stream ?? Stream<String>.fromIterable(lines),
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

    test('extracts usage metadata from streaming chunk', () async {
      final transport = FakeTransport(
        lines: <String>[
          'data: {"choices":[{"delta":{"content":"Hello"}}]}\n\n',
          'data: {"choices":[],"usage":{"prompt_tokens":15,"completion_tokens":5,"total_tokens":20,"prompt_tokens_details":{"cached_tokens":8}}}\n\n',
          'data: [DONE]\n\n',
        ],
      );
      final chunks =
          await backendWith(transport).stream(requestWith()).toList();
      final withUsage = chunks.firstWhere((ChatChunk c) => c.usage != null);
      expect(withUsage.usage?.promptTokens, 15);
      expect(withUsage.usage?.completionTokens, 5);
      expect(withUsage.usage?.totalTokens, 20);
      expect(withUsage.usage?.cachedTokens, 8);
    });

    test('extracts DeepSeek and Anthropic prompt cache tokens', () async {
      final deepseekTransport = FakeTransport(
        lines: <String>[
          'data: {"choices":[],"usage":{"prompt_tokens":100,"completion_tokens":20,"total_tokens":120,"prompt_cache_hit_tokens":85}}\n\n',
          'data: [DONE]\n\n',
        ],
      );
      final dsChunks =
          await backendWith(deepseekTransport).stream(requestWith()).toList();
      final dsUsage = dsChunks.firstWhere((ChatChunk c) => c.usage != null).usage;
      expect(dsUsage?.cachedTokens, 85);

      final anthropicTransport = FakeTransport(
        lines: <String>[
          'data: {"choices":[],"usage":{"prompt_tokens":200,"completion_tokens":40,"total_tokens":240,"cache_read_input_tokens":150}}\n\n',
          'data: [DONE]\n\n',
        ],
      );
      final antChunks =
          await backendWith(anthropicTransport).stream(requestWith()).toList();
      final antUsage = antChunks.firstWhere((ChatChunk c) => c.usage != null).usage;
      expect(antUsage?.cachedTokens, 150);
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

    test(
        'a connection-closed error after chunks arrive concludes the stream gracefully',
        () async {
      final StreamController<String> controller = StreamController<String>();
      controller.add(sse('Hello world'));
      controller.addError(Exception(
          'HttpException: Connection closed while receiving data, uri = ...'));

      final transport = FakeTransport(stream: controller.stream);
      final chunks =
          await backendWith(transport).stream(requestWith()).toList();
      expect(chunks.map((ChatChunk c) => c.delta).join(), 'Hello world');
      expect(chunks.last.done, isTrue);
    });

    test('a connection-closed error before any chunk throws', () async {
      final StreamController<String> controller = StreamController<String>();
      controller.addError(
          Exception('HttpException: Connection closed while receiving data'));

      final transport = FakeTransport(stream: controller.stream);
      expect(
        () => backendWith(transport).stream(requestWith()).toList(),
        throwsA(isA<Exception>()),
      );
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

  group('a base URL with no scheme', () {
    // The reported failure: sending a message threw
    // "Invalid argument(s): No host specified in URI" within milliseconds.
    // Uri.parse reads "api.deepseek.com/v1" as a relative reference with no
    // host, and HttpClient refuses it before any request leaves the device.

    test('a bare host gains a scheme', () {
      expect(
        OpenAiCompatibleBackend.normalizeBaseUrl('api.deepseek.com/v1'),
        'https://api.deepseek.com/v1',
      );
      expect(
        OpenAiCompatibleBackend.normalizeBaseUrl('api.openai.com'),
        'https://api.openai.com',
      );
    });

    test('a local address is assumed to be http, not https', () {
      for (final String host in <String>[
        'localhost:11434/v1',
        '127.0.0.1:1234/v1',
        '10.0.2.2:11434/v1',
        '192.168.1.50:8080/v1',
        '172.16.0.9:8000/v1',
        'ollama.local/v1',
      ]) {
        expect(
          OpenAiCompatibleBackend.normalizeBaseUrl(host),
          'http://$host',
          reason: '$host should not be forced onto https',
        );
      }
    });

    test('a public host is not mistaken for a local one', () {
      for (final String host in <String>[
        'api.deepseek.com',
        '10.example.com',
        '172.15.0.1',
        '172.32.0.1',
      ]) {
        expect(
          OpenAiCompatibleBackend.normalizeBaseUrl(host),
          'https://$host',
          reason: '$host should default to https',
        );
      }
    });

    test('looksLikeLocalHost classifies the boundary cases', () {
      expect(OpenAiCompatibleBackend.looksLikeLocalHost('172.16.0.1'), isTrue);
      expect(
          OpenAiCompatibleBackend.looksLikeLocalHost('172.31.255.255'), isTrue);
      expect(OpenAiCompatibleBackend.looksLikeLocalHost('172.15.0.1'), isFalse);
      expect(OpenAiCompatibleBackend.looksLikeLocalHost('172.32.0.1'), isFalse);
      expect(
          OpenAiCompatibleBackend.looksLikeLocalHost('192.169.1.1'), isFalse);
      expect(OpenAiCompatibleBackend.looksLikeLocalHost(''), isFalse);
    });

    test('the repaired URL yields a usable endpoint', () {
      final OpenAiCompatibleBackend backend = OpenAiCompatibleBackend(
        baseUrl: 'api.deepseek.com/v1',
        apiKey: 'sk-test',
        transport: FakeTransport(),
      );
      expect(backend.endpoint.host, 'api.deepseek.com');
      expect(backend.endpoint.scheme, 'https');
      expect(backend.endpoint.path, '/v1/chat/completions');
    });

    test('a URL that still has no host fails with an explanation', () {
      // Nothing left to normalise. The point is that the user reads a
      // configuration problem rather than a raw ArgumentError.
      final OpenAiCompatibleBackend backend = OpenAiCompatibleBackend(
        baseUrl: 'https://',
        apiKey: 'sk-test',
        transport: FakeTransport(),
      );
      expect(
        () => backend.endpoint,
        throwsA(
          predicate(
            (Object e) =>
                e is BackendException &&
                e.message.contains('no host') &&
                e.message.contains('https://api.openai.com/v1'),
          ),
        ),
      );
    });
  });

  group('listing models', () {
    test('reads the documented shape', () {
      expect(
        OpenAiCompatibleBackend.parseModelIds(
          '{"object":"list","data":[{"id":"gpt-4o"},{"id":"gpt-4o-mini"}]}',
        ),
        <String>['gpt-4o', 'gpt-4o-mini'],
      );
    });

    test('sorts, and drops duplicates and blanks', () {
      expect(
        OpenAiCompatibleBackend.parseModelIds(
          '{"data":[{"id":"zeta"},{"id":"alpha"},{"id":"zeta"},{"id":"  "}]}',
        ),
        <String>['alpha', 'zeta'],
      );
    });

    test('accepts bare strings, which some proxies return', () {
      expect(
        OpenAiCompatibleBackend.parseModelIds('{"data":["b","a"]}'),
        <String>['a', 'b'],
      );
    });

    test('anything unreadable is an empty list, not a throw', () {
      // The list is a convenience; failing to parse it must not look like a
      // broken endpoint.
      expect(
          OpenAiCompatibleBackend.parseModelIds('<html>nope</html>'), isEmpty);
      expect(OpenAiCompatibleBackend.parseModelIds('{"data":{}}'), isEmpty);
      expect(OpenAiCompatibleBackend.parseModelIds('[]'), isEmpty);
      expect(
          OpenAiCompatibleBackend.parseModelIds('{"data":[1,2,3]}'), isEmpty);
      expect(OpenAiCompatibleBackend.parseModelIds(''), isEmpty);
    });

    test('parses model context lengths when reported by provider', () {
      const String json = '{"data":['
          '{"id":"model-a","context_length":32768},'
          '{"id":"model-b","max_context_length":131072},'
          '{"id":"model-c"}'
          ']}';
      final lengths = OpenAiCompatibleBackend.parseModelContextLengths(json);
      expect(lengths['model-a'], 32768);
      expect(lengths['model-b'], 131072);
      expect(lengths.containsKey('model-c'), isFalse);
    });

    test('asks /models with the key attached', () async {
      final transport = FakeTransport(
        lines: <String>['{"data":[{"id":"deepseek-chat"}]}'],
      );
      final List<String> models = await backendWith(transport).listModels();

      expect(models, <String>['deepseek-chat']);
      expect(transport.lastUrl!.path, '/v1/models');
      expect(transport.lastUrl!.host, 'api.example.com');
      expect(transport.lastHeaders!['Authorization'], 'Bearer sk-test');
    });

    test('a rejected key is reported, not swallowed', () async {
      final transport = FakeTransport(
        statusCode: 401,
        lines: <String>['{"error":{"message":"Invalid API key"}}'],
      );
      await expectLater(
        backendWith(transport).listModels(),
        throwsA(
          predicate(
            (Object e) =>
                e is BackendException &&
                e.statusCode == 401 &&
                e.message.contains('Invalid API key'),
          ),
        ),
      );
    });

    test('a server with no /models is reported too', () async {
      final transport = FakeTransport(statusCode: 404, lines: <String>['{}']);
      await expectLater(
        backendWith(transport).listModels(),
        throwsA(isA<BackendException>()),
      );
    });
  });
}
