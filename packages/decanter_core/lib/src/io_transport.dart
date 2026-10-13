import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'backend.dart';

/// The real network transport, over `dart:io`.
///
/// Kept separate from [OpenAiCompatibleBackend] so the streaming parser can be
/// tested against a fake, and so a platform that is not `dart:io` could supply
/// its own transport without touching the client logic.
class IoHttpTransport implements HttpTransport {
  IoHttpTransport({
    HttpClient? client,
    this.connectTimeout = const Duration(seconds: 20),
    this.requestTimeout = const Duration(seconds: 180),
  }) : _client = client ?? HttpClient() {
    _client.connectionTimeout = connectTimeout;
  }

  final HttpClient _client;

  /// Time allowed to establish a connection.
  final Duration connectTimeout;

  /// Time allowed for a request to return its headers.
  ///
  /// Generous on purpose: a streamed reply that is still arriving is not a
  /// timeout, and cutting it off mid-sentence is worse than waiting.
  final Duration requestTimeout;

  @override
  Future<StreamedResponse> send({
    required String method,
    required Uri url,
    Map<String, String> headers = const <String, String>{},
    String? body,
  }) async {
    final HttpClientRequest request =
        await _client.openUrl(method, url).timeout(connectTimeout);

    headers.forEach(request.headers.set);

    // Ask for an uncompressed stream: gzip on a chunked SSE body defeats the
    // point of streaming, because the decoder buffers a whole block before it
    // can emit anything.
    if (!headers.keys.any((String k) => k.toLowerCase() == 'accept-encoding')) {
      request.headers.set('Accept-Encoding', 'identity');
    }

    if (body != null) request.write(body);

    final HttpClientResponse response =
        await request.close().timeout(requestTimeout);

    return StreamedResponse(
      statusCode: response.statusCode,
      lines: response.transform(utf8.decoder).transform(const LineSplitter()),
    );
  }

  @override
  void close() => _client.close(force: true);
}
