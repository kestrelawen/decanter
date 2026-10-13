/// Answers "what would the app see?" against the real GitHub API.
///
/// The app's update path cannot be exercised on this machine (no Android
/// device), but the network half of it can, using the same code the app calls.
///
/// Usage:
///   dart tool/check_update.dart [owner/repo] [installed-version]
///   dart tool/check_update.dart --download [owner/repo] [installed-version]
///
/// The token is read from GITHUB_TOKEN or GH_TOKEN and is only needed while the
/// repository is private. It is never printed.
import 'dart:io';

import 'package:decanter_core/decanter_core.dart';

Future<void> main(List<String> args) async {
  final List<String> rest =
      args.where((String a) => a != '--download').toList();
  final bool alsoDownload = args.contains('--download');

  final String repo = rest.isNotEmpty ? rest[0] : 'kestrelawen/decanter';
  final String installed = rest.length > 1 ? rest[1] : '0.2.0';
  final String token = Platform.environment['GITHUB_TOKEN'] ??
      Platform.environment['GH_TOKEN'] ??
      '';

  stdout.writeln('repo:       $repo');
  stdout.writeln('installed:  $installed');
  stdout.writeln(
      'token:      ${token.isEmpty ? 'none (public repo only)' : 'present, ${token.length} chars'}');
  stdout.writeln('');

  final IoHttpTransport transport = IoHttpTransport();
  final ReleaseClient client = ReleaseClient(
    transport: transport,
    token: token,
  );

  final UpdateCheck check = await client.checkForUpdate(
    repo: repo,
    currentVersion: Version.parse(installed),
  );

  stdout.writeln('status:     ${check.status.name}');
  stdout.writeln('message:    ${check.message}');

  final AppRelease? release = check.release;
  if (release == null) {
    transport.close();
    exit(check.status == UpdateStatus.failed ? 1 : 0);
  }

  stdout.writeln('tag:        ${release.tag}');
  stdout.writeln('version:    ${release.version}');
  stdout.writeln('title:      ${release.title}');
  stdout.writeln('assets:     ${release.assets.length}');
  for (final ReleaseAsset asset in release.assets) {
    stdout.writeln('  - ${asset.name}  ${asset.sizeBytes} bytes');
  }

  final ReleaseAsset? apk = release.apk;
  stdout.writeln('chosen apk: ${apk?.name ?? '(none)'}');
  if (apk == null) {
    transport.close();
    exit(0);
  }
  stdout.writeln('browser url: ${apk.downloadUrl}');
  stdout.writeln('will fetch:  ${client.downloadUriFor(apk, repo)}');

  if (!alsoDownload) {
    transport.close();
    exit(0);
  }

  // The half the unit tests cannot reach: a genuine 302 to signed object storage,
  // with a bearer token that must not survive the hop.
  stdout.writeln('');
  stdout.writeln('downloading via the app\'s own downloader...');

  final Directory workdir =
      Directory.systemTemp.createTempSync('decanter-check');
  final File target = File('${workdir.path}/${apk.name}');

  var lastReported = 0;
  final int written = await transport.downloadTo(
    // Not apk.downloadUrl: for a private repository the github.com browser URL
    // answers 404 to a bearer token, while the API asset endpoint 302s to
    // signed storage as intended.
    url: client.downloadUriFor(apk, repo),
    target: target,
    headers: <String, String>{
      'Accept': 'application/octet-stream',
      'User-Agent': 'Decanter',
      if (token.isNotEmpty) 'Authorization': 'Bearer $token',
    },
    onProgress: (int received, int total) {
      if (total > 0 && received - lastReported > 10 * 1024 * 1024) {
        lastReported = received;
        stdout.writeln(
          '  ${(received / 1048576).toStringAsFixed(1)} / '
          '${(total / 1048576).toStringAsFixed(1)} MB',
        );
      }
    },
  );

  stdout.writeln('wrote:      $written bytes');
  stdout.writeln('expected:   ${apk.sizeBytes} bytes');
  if (written != apk.sizeBytes) {
    stdout.writeln('MISMATCH');
    transport.close();
    exit(1);
  }
  stdout.writeln('sha256:     ${await _sha256(target)}');
  stdout.writeln('path:       ${target.path}');

  transport.close();
  exit(0);
}

/// `sha256sum` is present everywhere this runs; no need to implement it.
Future<String> _sha256(File file) async {
  final ProcessResult result =
      await Process.run('sha256sum', <String>[file.path]);
  return (result.stdout as String).trim().split(' ').first;
}
