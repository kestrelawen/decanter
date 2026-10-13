import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'backend.dart';

/// Reads a JSON value that should be a string, treating anything else as absent.
String _string(Object? value) => value is String ? value : '';

/// A dotted version, optionally with a build number and a pre-release tag.
///
/// Handles what actually appears in tags and in `pubspec.yaml`: `v0.2.0`,
/// `0.2.0+2`, `1.0.0-rc.1`.
class Version implements Comparable<Version> {
  const Version({required this.parts, this.build, this.preRelease});

  /// Numeric components, most significant first. Missing components compare as
  /// zero, so `1.2` and `1.2.0` are equal.
  final List<int> parts;

  /// The `+N` suffix, which Android uses and tags do not carry.
  final int? build;

  /// The `-suffix`, which sorts *below* the release it precedes.
  final String? preRelease;

  static const Version zero = Version(parts: <int>[0]);

  static Version parse(String raw) {
    var value = raw.trim();
    if (value.isEmpty) return zero;

    if (value.startsWith('v') || value.startsWith('V')) {
      value = value.substring(1);
    }

    int? build;
    final int plus = value.indexOf('+');
    if (plus != -1) {
      build = int.tryParse(value.substring(plus + 1).trim());
      value = value.substring(0, plus);
    }

    String? preRelease;
    final int dash = value.indexOf('-');
    if (dash != -1) {
      preRelease = value.substring(dash + 1).trim();
      value = value.substring(0, dash);
    }

    final List<int> parts = <int>[
      for (final String piece in value.split('.'))
        int.tryParse(piece.trim()) ?? 0,
    ];

    return Version(
      parts: parts.isEmpty ? <int>[0] : parts,
      build: build,
      preRelease: preRelease,
    );
  }

  @override
  int compareTo(Version other) {
    final int length = math.max(parts.length, other.parts.length);
    for (var i = 0; i < length; i++) {
      final int a = i < parts.length ? parts[i] : 0;
      final int b = i < other.parts.length ? other.parts[i] : 0;
      if (a != b) return a.compareTo(b);
    }

    // A pre-release precedes the release it leads up to: 1.0.0-rc.1 < 1.0.0.
    final String mine = preRelease ?? '';
    final String theirs = other.preRelease ?? '';
    if (mine.isEmpty != theirs.isEmpty) return theirs.isEmpty ? -1 : 1;
    final int byPre = mine.compareTo(theirs);
    if (byPre != 0) return byPre;

    return (build ?? 0).compareTo(other.build ?? 0);
  }

  bool operator >(Version other) => compareTo(other) > 0;
  bool operator <(Version other) => compareTo(other) < 0;
  bool operator >=(Version other) => compareTo(other) >= 0;
  bool operator <=(Version other) => compareTo(other) <= 0;

  @override
  bool operator ==(Object other) => other is Version && compareTo(other) == 0;

  @override
  int get hashCode => Object.hashAll(<Object?>[
        ...parts,
        build,
        preRelease,
      ]);

  @override
  String toString() {
    final String core = parts.join('.');
    final String pre = preRelease == null ? '' : '-$preRelease';
    final String b = build == null ? '' : '+$build';
    return '$core$pre$b';
  }
}

/// One downloadable file attached to a release.
class ReleaseAsset {
  const ReleaseAsset({
    required this.name,
    required this.downloadUrl,
    required this.sizeBytes,
  });

  final String name;
  final Uri downloadUrl;
  final int sizeBytes;

  /// True for the files worth offering to install.
  bool get isApk => name.toLowerCase().endsWith('.apk');

  @override
  String toString() => 'ReleaseAsset($name, $sizeBytes bytes)';
}

/// A published release.
class AppRelease {
  const AppRelease({
    required this.tag,
    required this.title,
    required this.notes,
    required this.assets,
    this.publishedAt,
    this.prerelease = false,
  });

  final String tag;
  final String title;
  final String notes;
  final List<ReleaseAsset> assets;
  final DateTime? publishedAt;
  final bool prerelease;

  Version get version => Version.parse(tag);

  /// The APK to install, if the release published one.
  ///
  /// Prefers a name containing `decanter` when several are attached, so a
  /// per-ABI split build does not hand back an arbitrary one.
  ReleaseAsset? get apk {
    final List<ReleaseAsset> apks = <ReleaseAsset>[
      for (final ReleaseAsset asset in assets)
        if (asset.isApk) asset,
    ];
    if (apks.isEmpty) return null;
    for (final ReleaseAsset asset in apks) {
      if (asset.name.toLowerCase().contains('decanter')) return asset;
    }
    return apks.first;
  }

  factory AppRelease.fromJson(Map<String, dynamic> json) => AppRelease(
        tag: _string(json['tag_name']),
        title: _string(json['name']).isEmpty
            ? _string(json['tag_name'])
            : _string(json['name']),
        notes: _string(json['body']),
        publishedAt: DateTime.tryParse(_string(json['published_at'])),
        prerelease: json['prerelease'] == true || json['draft'] == true,
        assets: <ReleaseAsset>[
          if (json['assets'] is List)
            for (final Object? raw in json['assets'] as List<dynamic>)
              if (raw is Map)
                ReleaseAsset(
                  name: _string(raw['name']),
                  downloadUrl:
                      Uri.tryParse(_string(raw['browser_download_url'])) ??
                          Uri(),
                  sizeBytes: raw['size'] is int ? raw['size'] as int : 0,
                ),
        ],
      );

  @override
  String toString() => 'AppRelease($tag, ${assets.length} assets)';
}

enum UpdateStatus {
  /// The published release is not newer than what is installed.
  upToDate,

  /// A newer release exists and carries an installable APK.
  updateAvailable,

  /// The repository has no releases yet, or is not visible to this client.
  noReleases,

  /// A newer tag exists but published no APK, so there is nothing to install.
  noInstallableAsset,

  /// The check itself failed — network, auth, or an unreadable response.
  failed,
}

/// The outcome of an update check, with a message fit to show a person.
class UpdateCheck {
  const UpdateCheck({
    required this.status,
    this.release,
    this.message = '',
  });

  final UpdateStatus status;
  final AppRelease? release;
  final String message;

  bool get hasUpdate => status == UpdateStatus.updateAvailable;

  @override
  String toString() =>
      'UpdateCheck(${status.name}${message.isEmpty ? '' : ', $message'})';
}

/// Asks GitHub what the latest release is, and whether it is worth installing.
class ReleaseClient {
  ReleaseClient({
    required this.transport,
    this.token = '',
    String apiBase = 'https://api.github.com',
  }) : _apiBase = apiBase.endsWith('/')
            ? apiBase.substring(0, apiBase.length - 1)
            : apiBase;

  final HttpTransport transport;

  /// Optional. Required only for a private repository, where GitHub answers 404
  /// rather than 403 for an unauthenticated request — it does not confirm the
  /// repository exists.
  final String token;

  final String _apiBase;

  Uri latestUri(String repo) =>
      Uri.parse('$_apiBase/repos/$repo/releases/latest');

  Map<String, String> _headers() => <String, String>{
        'Accept': 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
        // GitHub rejects API requests with no User-Agent.
        'User-Agent': 'Decanter',
        'Accept-Encoding': 'identity',
        if (token.trim().isNotEmpty) 'Authorization': 'Bearer ${token.trim()}',
      };

  /// Fetches the latest release and compares it against [currentVersion].
  Future<UpdateCheck> checkForUpdate({
    required String repo,
    required Version currentVersion,
  }) async {
    if (repo.trim().isEmpty || !repo.contains('/')) {
      return const UpdateCheck(
        status: UpdateStatus.failed,
        message:
            'No repository configured. Expected something like owner/name.',
      );
    }

    final StreamedResponse response;
    try {
      response = await transport.send(
        method: 'GET',
        url: latestUri(repo.trim()),
        headers: _headers(),
      );
    } on Object catch (error) {
      return UpdateCheck(
        status: UpdateStatus.failed,
        message: 'Could not reach GitHub: $error',
      );
    }

    final String body = await StreamedResponse.collect(response.lines);

    switch (response.statusCode) {
      case 200:
        break;
      case 404:
        return UpdateCheck(
          status: UpdateStatus.noReleases,
          message: token.trim().isEmpty
              ? 'No releases found. If the repository is private, add a '
                  'read-only token — GitHub reports a private repository as '
                  'not found rather than as forbidden.'
              : 'No releases found, or the token cannot read this repository.',
        );
      case 401:
        return const UpdateCheck(
          status: UpdateStatus.failed,
          message:
              'The token was rejected (401). Check that it has not expired.',
        );
      case 403:
        return const UpdateCheck(
          status: UpdateStatus.failed,
          message: 'GitHub refused the request (403). This is usually a rate '
              'limit, or a token without permission to read contents.',
        );
      default:
        return UpdateCheck(
          status: UpdateStatus.failed,
          message: 'GitHub returned HTTP ${response.statusCode}.',
        );
    }

    final AppRelease? release = parseRelease(body);
    if (release == null) {
      return const UpdateCheck(
        status: UpdateStatus.failed,
        message: 'GitHub sent a response this app could not read.',
      );
    }

    if (release.version <= currentVersion) {
      return UpdateCheck(
        status: UpdateStatus.upToDate,
        release: release,
        message: 'Up to date (${currentVersion.toString()}).',
      );
    }

    if (release.apk == null) {
      return UpdateCheck(
        status: UpdateStatus.noInstallableAsset,
        release: release,
        message: 'Version ${release.version.toString()} is published but has '
            'no APK attached.',
      );
    }

    return UpdateCheck(
      status: UpdateStatus.updateAvailable,
      release: release,
      message: 'Version ${release.version.toString()} is available.',
    );
  }

  /// Parses one release object, or null when the body is not one.
  static AppRelease? parseRelease(String body) {
    try {
      final Object? decoded = jsonDecode(body);
      if (decoded is Map) {
        final Map<String, dynamic> map = Map<String, dynamic>.from(decoded);
        // A 200 response to /releases/latest is always an object, but be
        // defensive: some proxies answer with an array.
        if (map['tag_name'] is! String) return null;
        return AppRelease.fromJson(map);
      }
    } on FormatException {
      return null;
    }
    return null;
  }
}

/// Downloads a file to disk.
///
/// Separate from [HttpTransport], which is line-oriented for SSE. A 50MB APK
/// belongs in a file, not in a string.
abstract class FileDownloader {
  /// Returns the number of bytes written.
  Future<int> downloadTo({
    required Uri url,
    required File target,
    Map<String, String> headers = const <String, String>{},
    void Function(int received, int total)? onProgress,
  });
}
