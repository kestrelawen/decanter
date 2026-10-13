import 'dart:convert';
import 'dart:io';

import 'package:decanter_core/decanter_core.dart';
import 'package:test/test.dart';

/// A transport that replays a canned HTTP response.
class FakeTransport implements HttpTransport {
  FakeTransport({this.statusCode = 200, this.body = '{}', this.throwError});

  final int statusCode;

  /// The canned response body. Read in [send] as `this.body`, because that
  /// method's own `body` parameter shadows the field.
  final String body;
  final Object? throwError;

  Uri? lastUrl;
  Map<String, String>? lastHeaders;
  int calls = 0;

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
    if (throwError != null) throw throwError!;
    return StreamedResponse(
      statusCode: statusCode,
      lines: Stream<String>.fromIterable(this.body.split('\n')),
    );
  }

  @override
  void close() {}
}

String releaseJson({
  String tag = 'v0.3.0',
  String name = 'Decanter 0.3.0',
  String body = 'notes',
  List<Map<String, Object>>? assets,
  bool prerelease = false,
}) =>
    jsonEncode(<String, dynamic>{
      'tag_name': tag,
      'name': name,
      'body': body,
      'published_at': '2026-10-13T21:00:00Z',
      'prerelease': prerelease,
      'draft': false,
      'assets': assets ??
          <Map<String, Object>>[
            <String, Object>{
              'name': 'decanter-0.3.0.apk',
              'browser_download_url':
                  'https://github.com/kestrelawen/decanter/releases/download/v0.3.0/decanter-0.3.0.apk',
              'size': 50000000,
            },
          ],
    });

void main() {
  group('Version parsing', () {
    test('reads a plain tag', () {
      final Version v = Version.parse('v0.2.0');
      expect(v.parts, <int>[0, 2, 0]);
      expect(v.build, isNull);
      expect(v.preRelease, isNull);
    });

    test('reads a build suffix', () {
      final Version v = Version.parse('0.2.0+2');
      expect(v.parts, <int>[0, 2, 0]);
      expect(v.build, 2);
    });

    test('reads a pre-release suffix', () {
      final Version v = Version.parse('1.0.0-rc.1');
      expect(v.parts, <int>[1, 0, 0]);
      expect(v.preRelease, 'rc.1');
    });

    test('reads both suffixes at once', () {
      final Version v = Version.parse('v1.2.3-beta+7');
      expect(v.parts, <int>[1, 2, 3]);
      expect(v.preRelease, 'beta');
      expect(v.build, 7);
    });

    test('an empty or junk string is zero rather than an exception', () {
      expect(Version.parse(''), Version.zero);
      expect(Version.parse('   '), Version.zero);
      expect(Version.parse('wat').parts, <int>[0]);
    });

    test('round-trips through toString', () {
      expect(Version.parse('v1.2.3-beta+7').toString(), '1.2.3-beta+7');
      expect(Version.parse('0.2.0').toString(), '0.2.0');
    });
  });

  group('Version comparison', () {
    test('orders by component', () {
      expect(Version.parse('0.2.0') < Version.parse('0.2.1'), isTrue);
      expect(Version.parse('0.2.0') < Version.parse('0.10.0'), isTrue);
      expect(Version.parse('1.0.0') > Version.parse('0.9.9'), isTrue);
    });

    test('missing components compare as zero', () {
      expect(Version.parse('1.2'), Version.parse('1.2.0'));
    });

    test('a pre-release precedes its release', () {
      expect(Version.parse('1.0.0-rc.1') < Version.parse('1.0.0'), isTrue);
      expect(Version.parse('1.0.0') > Version.parse('1.0.0-rc.1'), isTrue);
    });

    test('a higher build number wins at the same version', () {
      // This is what keeps the app from re-offering the build it is already
      // running: the tag says 0.2.0, the installed version says 0.2.0+2.
      expect(Version.parse('0.2.0+2') > Version.parse('0.2.0'), isTrue);
      expect(Version.parse('0.2.0+2') > Version.parse('v0.2.0'), isTrue);
    });

    test('equality ignores a leading v', () {
      expect(Version.parse('v0.2.0'), Version.parse('0.2.0'));
    });
  });

  group('release parsing', () {
    test('reads the fields that matter', () {
      final AppRelease? release =
          ReleaseClient.parseRelease(releaseJson(body: 'hello'));
      expect(release, isNotNull);
      expect(release!.tag, 'v0.3.0');
      expect(release.version, Version.parse('0.3.0'));
      expect(release.notes, 'hello');
      expect(release.apk, isNotNull);
      expect(release.apk!.sizeBytes, 50000000);
      expect(release.apk!.downloadUrl.host, 'github.com');
    });

    test('falls back to the tag when the release has no title', () {
      final AppRelease? release = ReleaseClient.parseRelease(
        jsonEncode(<String, dynamic>{'tag_name': 'v1.0.0', 'name': ''}),
      );
      expect(release!.title, 'v1.0.0');
    });

    test('finds the APK among several assets, preferring ours', () {
      final AppRelease? release = ReleaseClient.parseRelease(
        releaseJson(
          assets: <Map<String, Object>>[
            <String, Object>{
              'name': 'checksums.txt',
              'browser_download_url': 'https://example.com/a.txt',
              'size': 10,
            },
            <String, Object>{
              'name': 'app-release.apk',
              'browser_download_url': 'https://example.com/generic.apk',
              'size': 1,
            },
            <String, Object>{
              'name': 'decanter-0.3.0.apk',
              'browser_download_url': 'https://example.com/ours.apk',
              'size': 2,
            },
          ],
        ),
      );
      expect(release!.apk!.name, 'decanter-0.3.0.apk');
    });

    test('a release with no APK reports none', () {
      final AppRelease? release = ReleaseClient.parseRelease(
        releaseJson(assets: <Map<String, Object>>[]),
      );
      expect(release!.apk, isNull);
    });

    test('junk is rejected rather than half-parsed', () {
      expect(ReleaseClient.parseRelease('<html>nope</html>'), isNull);
      expect(ReleaseClient.parseRelease('{}'), isNull);
      expect(ReleaseClient.parseRelease('[]'), isNull);
    });
  });

  group('update check', () {
    test('a newer release with an APK is an update', () async {
      final transport = FakeTransport(body: releaseJson(tag: 'v0.3.0'));
      final UpdateCheck check = await ReleaseClient(
        transport: transport,
      ).checkForUpdate(
        repo: 'kestrelawen/decanter',
        currentVersion: Version.parse('0.2.0'),
      );

      expect(check.status, UpdateStatus.updateAvailable);
      expect(check.hasUpdate, isTrue);
      expect(check.release!.tag, 'v0.3.0');
      expect(check.message, contains('0.3.0'));
    });

    test('the same version is up to date', () async {
      final transport = FakeTransport(body: releaseJson(tag: 'v0.2.0'));
      final UpdateCheck check = await ReleaseClient(
        transport: transport,
      ).checkForUpdate(
        repo: 'kestrelawen/decanter',
        currentVersion: Version.parse('0.2.0'),
      );
      expect(check.status, UpdateStatus.upToDate);
      expect(check.hasUpdate, isFalse);
    });

    test('an older release is not an update', () async {
      final transport = FakeTransport(body: releaseJson(tag: 'v0.1.0'));
      final UpdateCheck check = await ReleaseClient(
        transport: transport,
      ).checkForUpdate(
        repo: 'kestrelawen/decanter',
        currentVersion: Version.parse('0.2.0'),
      );
      expect(check.status, UpdateStatus.upToDate);
    });

    test('a newer release with no APK says so instead of offering it',
        () async {
      final transport = FakeTransport(
        body: releaseJson(tag: 'v0.3.0', assets: <Map<String, Object>>[]),
      );
      final UpdateCheck check = await ReleaseClient(
        transport: transport,
      ).checkForUpdate(
        repo: 'kestrelawen/decanter',
        currentVersion: Version.parse('0.2.0'),
      );
      expect(check.status, UpdateStatus.noInstallableAsset);
      expect(check.message, contains('no APK'));
    });

    test('404 explains the private-repository trap', () async {
      // GitHub answers 404 — not 403 — for a private repo without a token, so a
      // bare "not found" would send someone hunting for a typo in the name.
      final transport =
          FakeTransport(statusCode: 404, body: '{"message":"Not Found"}');
      final UpdateCheck check = await ReleaseClient(
        transport: transport,
      ).checkForUpdate(
        repo: 'kestrelawen/decanter',
        currentVersion: Version.parse('0.2.0'),
      );
      expect(check.status, UpdateStatus.noReleases);
      expect(check.message, contains('private'));
      expect(check.message, contains('token'));
    });

    test('401 and 403 are reported distinctly', () async {
      final expired = await ReleaseClient(
        transport: FakeTransport(statusCode: 401, body: '{}'),
      ).checkForUpdate(repo: 'a/b', currentVersion: Version.zero);
      expect(expired.status, UpdateStatus.failed);
      expect(expired.message, contains('401'));

      final limited = await ReleaseClient(
        transport: FakeTransport(statusCode: 403, body: '{}'),
      ).checkForUpdate(repo: 'a/b', currentVersion: Version.zero);
      expect(limited.status, UpdateStatus.failed);
      expect(limited.message, contains('403'));
    });

    test('a server error is reported, not thrown', () async {
      final check = await ReleaseClient(
        transport: FakeTransport(statusCode: 500, body: 'boom'),
      ).checkForUpdate(repo: 'a/b', currentVersion: Version.zero);
      expect(check.status, UpdateStatus.failed);
      expect(check.message, contains('500'));
    });

    test('an unreadable body is reported, not thrown', () async {
      final check = await ReleaseClient(
        transport: FakeTransport(body: '<html>proxy</html>'),
      ).checkForUpdate(repo: 'a/b', currentVersion: Version.zero);
      expect(check.status, UpdateStatus.failed);
      expect(check.message, contains('could not read'));
    });

    test('a network failure is reported, not thrown', () async {
      final check = await ReleaseClient(
        transport: FakeTransport(throwError: const SocketException('no route')),
      ).checkForUpdate(repo: 'a/b', currentVersion: Version.zero);
      expect(check.status, UpdateStatus.failed);
      expect(check.message, contains('Could not reach GitHub'));
    });

    test('a malformed repo slug fails without touching the network', () async {
      final transport = FakeTransport();
      final check = await ReleaseClient(
        transport: transport,
      ).checkForUpdate(repo: 'nonsense', currentVersion: Version.zero);
      expect(check.status, UpdateStatus.failed);
      expect(transport.calls, 0);
    });

    test('the request carries a User-Agent and no auth by default', () async {
      final transport = FakeTransport(body: releaseJson());
      await ReleaseClient(transport: transport).checkForUpdate(
        repo: 'kestrelawen/decanter',
        currentVersion: Version.zero,
      );
      expect(transport.lastHeaders!['User-Agent'], 'Decanter');
      expect(transport.lastHeaders!.containsKey('Authorization'), isFalse);
      expect(transport.lastUrl.toString(),
          endsWith('/repos/kestrelawen/decanter/releases/latest'));
    });

    test('a token is sent as a bearer credential when configured', () async {
      final transport = FakeTransport(body: releaseJson());
      await ReleaseClient(
        transport: transport,
        token: 'ghp_example',
      ).checkForUpdate(
          repo: 'kestrelawen/decanter', currentVersion: Version.zero);
      expect(transport.lastHeaders!['Authorization'], 'Bearer ghp_example');
    });
  });

  group('downloader', () {
    late HttpServer server;
    late IoHttpTransport transport;
    late Directory workdir;

    setUp(() async {
      // anyIPv4 so a redirect can be aimed at a second loopback address
      // (127.0.0.2) and register as a different host without needing DNS.
      server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      transport = IoHttpTransport();
      workdir = Directory.systemTemp.createTempSync('decanter-dl');
    });

    tearDown(() async {
      transport.close();
      await server.close(force: true);
      if (workdir.existsSync()) workdir.deleteSync(recursive: true);
    });

    test('writes the bytes and reports progress', () async {
      final List<int> payload = List<int>.generate(200000, (int i) => i % 251);
      server.listen((HttpRequest request) {
        request.response
          ..statusCode = 200
          ..headers.contentLength = payload.length
          ..add(payload);
        request.response.close();
      });

      final File target = File('${workdir.path}/update.apk');
      final List<int> progress = <int>[];
      final int written = await transport.downloadTo(
        url: Uri.parse('http://127.0.0.1:${server.port}/apk'),
        target: target,
        onProgress: (int received, int total) => progress.add(received),
      );

      expect(written, payload.length);
      expect(target.existsSync(), isTrue);
      expect(await target.readAsBytes(), payload);
      expect(progress, isNotEmpty);
      expect(progress.last, payload.length);
      // The partial file must be gone once the rename has happened.
      expect(File('${target.path}.part').existsSync(), isFalse);
    });

    test('a same-host redirect keeps the Authorization header', () async {
      final List<String> seen = <String>[];
      final List<int> payload = List<int>.generate(1024, (int i) => i % 251);

      server.listen((HttpRequest request) async {
        seen.add(request.headers.value('authorization') ?? '(none)');
        if (request.uri.path == '/start') {
          request.response
            ..statusCode = 302
            ..headers.set('location', 'http://127.0.0.1:${server.port}/final');
          await request.response.close();
        } else {
          request.response
            ..statusCode = 200
            ..headers.contentLength = payload.length
            ..add(payload);
          await request.response.close();
        }
      });

      final File target = File('${workdir.path}/same-host.apk');
      final int written = await transport.downloadTo(
        url: Uri.parse('http://127.0.0.1:${server.port}/start'),
        target: target,
        headers: const <String, String>{'Authorization': 'Bearer secret'},
      );

      expect(written, payload.length);
      expect(seen, <String>['Bearer secret', 'Bearer secret']);
    });

    test('a cross-host redirect drops the Authorization header', () async {
      // This is the GitHub shape: a release asset 302s to signed object storage,
      // which rejects a request carrying both its own signature and our bearer
      // token. If the header survives the hop, the download 400s.
      final List<String> seen = <String>[];
      final List<int> payload = List<int>.generate(1024, (int i) => i % 251);

      server.listen((HttpRequest request) async {
        seen.add(request.headers.value('authorization') ?? '(none)');
        if (request.uri.path == '/start') {
          request.response
            ..statusCode = 302
            ..headers.set('location', 'http://127.0.0.2:${server.port}/final');
          await request.response.close();
        } else {
          request.response
            ..statusCode = 200
            ..headers.contentLength = payload.length
            ..add(payload);
          await request.response.close();
        }
      });

      final File target = File('${workdir.path}/cross-host.apk');
      final int written = await transport.downloadTo(
        url: Uri.parse('http://127.0.0.1:${server.port}/start'),
        target: target,
        headers: const <String, String>{'Authorization': 'Bearer secret'},
      );

      expect(written, payload.length);
      expect(seen, <String>['Bearer secret', '(none)']);
    });

    test('a relative redirect is resolved against the current URL', () async {
      final List<String> seen = <String>[];
      final List<int> payload = List<int>.generate(512, (int i) => i % 251);

      server.listen((HttpRequest request) async {
        seen.add(request.headers.value('authorization') ?? '(none)');
        if (request.uri.path == '/start') {
          request.response
            ..statusCode = 302
            ..headers.set('location', '/final');
          await request.response.close();
        } else {
          request.response
            ..statusCode = 200
            ..headers.contentLength = payload.length
            ..add(payload);
          await request.response.close();
        }
      });

      final File target = File('${workdir.path}/relative.apk');
      expect(
        await transport.downloadTo(
          url: Uri.parse('http://127.0.0.1:${server.port}/start'),
          target: target,
          headers: const <String, String>{'Authorization': 'Bearer secret'},
        ),
        payload.length,
      );
      // Same host, so the credential is retained.
      expect(seen, <String>['Bearer secret', 'Bearer secret']);
    });

    test('a redirect loop gives up instead of spinning', () async {
      server.listen((HttpRequest request) async {
        request.response
          ..statusCode = 302
          ..headers.set('location', '/again');
        await request.response.close();
      });

      final File target = File('${workdir.path}/loop.apk');
      await expectLater(
        transport.downloadTo(
          url: Uri.parse('http://127.0.0.1:${server.port}/start'),
          target: target,
        ),
        throwsA(isA<BackendException>()),
      );
      expect(target.existsSync(), isFalse);
    });

    test('a non-200 response leaves no file behind at all', () async {
      server.listen((HttpRequest request) {
        request.response.statusCode = 404;
        request.response.close();
      });

      final File target = File('${workdir.path}/missing.apk');
      await expectLater(
        transport.downloadTo(
          url: Uri.parse('http://127.0.0.1:${server.port}/nope'),
          target: target,
        ),
        throwsA(isA<BackendException>()),
      );
      expect(target.existsSync(), isFalse);
      expect(File('${target.path}.part').existsSync(), isFalse);
    });

    test('an interrupted download leaves no file that looks complete',
        () async {
      // Announced as 1MB, delivers 4KB, then hangs up. Without the .part rename
      // this would land as a truncated APK that the installer refuses with no
      // explanation.
      final List<int> payload = List<int>.generate(4096, (int i) => i % 251);
      server.listen((HttpRequest request) async {
        request.response
          ..statusCode = 200
          ..headers.contentLength = 1000000
          ..add(payload);
        try {
          await request.response.close();
        } on Object {
          // The SERVER also knows it wrote 4KB against a declared 1MB, so its own
          // close() fails with "Content size below specified contentLength". That
          // error belongs to this fixture, not to the code under test, and it
          // arrives on no future the test awaits — so it has to be swallowed here
          // or it reaches the runner as an unhandled error. Confirmed with a
          // standalone repro: it is raised server-side, and its `uri` is the
          // request path rather than a client URL.
        }
      });

      final File target = File('${workdir.path}/truncated.apk');
      await expectLater(
        transport.downloadTo(
          url: Uri.parse('http://127.0.0.1:${server.port}/short'),
          target: target,
        ),
        throwsA(isA<BackendException>()),
      );

      expect(target.existsSync(), isFalse);
      expect(File('${target.path}.part').existsSync(), isFalse);
    });
  });
}
