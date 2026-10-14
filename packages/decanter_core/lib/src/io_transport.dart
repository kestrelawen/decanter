import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'backend.dart';
import 'updater.dart';

/// The real network transport, over `dart:io`.
///
/// Kept separate from [OpenAiCompatibleBackend] so the streaming parser can be
/// tested against a fake, and so a platform that is not `dart:io` could supply
/// its own transport without touching the client logic.
class IoHttpTransport implements HttpTransport, FileDownloader {
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

    request.encoding = utf8;
    if (body != null) {
      final List<int> bytes = utf8.encode(body);
      request.headers.contentLength = bytes.length;
      request.add(bytes);
    }

    final HttpClientResponse response =
        await request.close().timeout(requestTimeout);

    return StreamedResponse(
      statusCode: response.statusCode,
      lines: response.transform(utf8.decoder).transform(const LineSplitter()),
    );
  }

  /// How many redirects a download will follow before giving up.
  static const int _maxRedirects = 5;

  @override
  Future<int> downloadTo({
    required Uri url,
    required File target,
    Map<String, String> headers = const <String, String>{},
    void Function(int received, int total)? onProgress,
  }) async {
    // Redirects are followed by hand. GitHub answers a release-asset URL with a
    // 302 to signed object storage, and forwarding the Authorization header
    // across that hop makes the storage host reject the request outright — the
    // classic "only one auth mechanism allowed" 400. Dart's automatic redirect
    // handling does not drop it, so the credential has to be stripped here.
    Uri current = url;
    final Map<String, String> currentHeaders =
        Map<String, String>.from(headers);
    HttpClientResponse response;
    var redirects = 0;

    while (true) {
      final HttpClientRequest request =
          await _client.getUrl(current).timeout(connectTimeout);
      request.followRedirects = false;

      currentHeaders.forEach(request.headers.set);
      if (!currentHeaders.keys.any(
        (String k) => k.toLowerCase() == 'accept-encoding',
      )) {
        request.headers.set('Accept-Encoding', 'identity');
      }

      response = await request.close().timeout(requestTimeout);

      final String? location = response.headers.value(
        HttpHeaders.locationHeader,
      );
      final bool isRedirect = response.statusCode >= 300 &&
          response.statusCode < 400 &&
          location != null;
      if (!isRedirect) break;

      await response.drain<void>();

      if (redirects >= _maxRedirects) {
        throw BackendException(
          message: 'Download redirected more than $_maxRedirects times.',
          statusCode: response.statusCode,
        );
      }
      redirects++;

      final Uri next = current.resolve(location);
      if (next.host != current.host) {
        currentHeaders.removeWhere(
          (String k, String _) => k.toLowerCase() == 'authorization',
        );
      }
      current = next;
    }

    if (response.statusCode != 200) {
      // Drain the body so the connection can be reused, then report.
      await response.drain<void>();
      throw BackendException(
        message: 'Download failed',
        statusCode: response.statusCode,
      );
    }

    // Written to a sibling `.part` and renamed only once the bytes are all
    // there. A truncated APK that looks like a finished download is worse than
    // no download at all — the installer would just refuse it, with no clue why.
    final File partial = File('${target.path}.part');
    partial.parent.createSync(recursive: true);

    final int total = response.contentLength;
    final IOSink sink = partial.openWrite();
    var received = 0;
    try {
      await for (final List<int> chunk in response) {
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(received, total);
      }
      await sink.flush();
      await sink.close();
    } on Object catch (error) {
      await sink.close();
      if (partial.existsSync()) partial.deleteSync();
      // Typed, so callers get something they can show a person rather than a
      // bare HttpException.
      throw BackendException(message: 'Download interrupted: $error');
    }

    // A short body closed cleanly is not an error at the socket level, so
    // without this check a truncated APK is renamed into place and the installer
    // refuses it with no explanation. `contentLength` is -1 when the response is
    // chunked and the size is unknown, hence the guard.
    if (total > 0 && received != total) {
      if (partial.existsSync()) partial.deleteSync();
      throw BackendException(
        message: 'Download incomplete: received $received of $total bytes.',
        statusCode: 200,
      );
    }

    if (target.existsSync()) target.deleteSync();
    partial.renameSync(target.path);
    return received;
  }

  @override
  void close() => _client.close(force: true);
}
