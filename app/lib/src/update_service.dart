import 'dart:io';

import 'package:decanter_core/decanter_core.dart';
import 'package:flutter/services.dart';

import 'settings.dart';

/// The method channel [MainActivity] answers on. Must match the Kotlin side
/// exactly — a typo here fails at runtime as a `MissingPluginException`, not at
/// build time, so it is a named constant rather than a literal at each call.
const String updateChannelName = 'app.decanter/updates';

/// The version this binary was built from.
///
/// Injected with `--dart-define=DECANTER_VERSION=...`, which the build workflow
/// reads straight out of `pubspec.yaml`. That is deliberate: a version string
/// maintained by hand in two places drifts, and the updater's whole job is
/// comparing this against a release tag.
const String appVersion = String.fromEnvironment(
  'DECANTER_VERSION',
  defaultValue: '0.0.0',
);

/// Parsed form of [appVersion].
Version get installedVersion => Version.parse(appVersion);

/// Where an update flow currently is.
enum UpdatePhase { idle, checking, updateAvailable, downloading, installing, failed }

/// What the update screen draws.
class UpdateProgress {
  const UpdateProgress({
    required this.phase,
    this.message = '',
    this.release,
    this.received = 0,
    this.total = 0,
  });

  final UpdatePhase phase;

  /// A sentence fit to show a person.
  final String message;

  final AppRelease? release;
  final int received;
  final int total;

  /// 0..1 while downloading, or null when the server did not declare a size.
  double? get fraction => total > 0 ? received / total : null;

  UpdateProgress copyWith({
    UpdatePhase? phase,
    String? message,
    AppRelease? release,
    int? received,
    int? total,
  }) => UpdateProgress(
    phase: phase ?? this.phase,
    message: message ?? this.message,
    release: release ?? this.release,
    received: received ?? this.received,
    total: total ?? this.total,
  );
}

/// Checks GitHub for a newer build, downloads it, and hands it to the installer.
///
/// The checking and version logic lives in `decanter_core` and is unit-tested
/// there. What is left here is the platform handoff, which cannot be tested
/// without a device.
class UpdateService {
  UpdateService({
    HttpTransport? transport,
    FileDownloader? downloader,
    MethodChannel? channel,
  }) : _transport = transport,
       _downloader = downloader,
       _channel = channel ?? const MethodChannel(updateChannelName);

  final HttpTransport? _transport;
  final FileDownloader? _downloader;
  final MethodChannel _channel;

  /// Only created if the caller did not supply one. Kept so [dispose] can close
  /// the underlying HttpClient rather than leaking sockets.
  IoHttpTransport? _owned;

  IoHttpTransport get _io => _owned ??= IoHttpTransport();
  HttpTransport get _effectiveTransport => _transport ?? _io;
  FileDownloader get _effectiveDownloader => _downloader ?? _io;

  void dispose() {
    _owned?.close();
    _owned = null;
  }

  /// Asks GitHub what the latest release is.
  Future<UpdateCheck> checkForUpdate(AppSettings settings) =>
      ReleaseClient(
        transport: _effectiveTransport,
        token: settings.updateToken,
      ).checkForUpdate(
        repo: settings.updateRepo,
        currentVersion: installedVersion,
      );

  /// Whether Android will let this app launch the installer.
  Future<bool> canInstallPackages() async {
    try {
      return await _channel.invokeMethod<bool>('canInstallPackages') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      // Running somewhere without the platform side (a widget test, a desktop
      // build): treat as "cannot install" rather than crashing the screen.
      return false;
    }
  }

  /// Opens the "install unknown apps" screen for this app.
  Future<bool> openInstallSettings() async {
    try {
      return await _channel.invokeMethod<bool>('openInstallSettings') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// The directory the platform gave us for staging downloads.
  Future<Directory> updateDirectory() async {
    final String? path = await _channel.invokeMethod<String>('updateDirectory');
    if (path == null || path.isEmpty) {
      throw FileSystemException('The platform returned no update directory.');
    }
    final Directory directory = Directory(path);
    if (!directory.existsSync()) directory.createSync(recursive: true);
    return directory;
  }

  /// Downloads the APK attached to [release] and returns the finished file.
  Future<File> downloadUpdate(
    AppRelease release, {
    required AppSettings settings,
    void Function(int received, int total)? onProgress,
  }) async {
    final ReleaseAsset? asset = release.apk;
    if (asset == null) {
      throw StateError('That release has no APK attached.');
    }

    final Directory directory = await updateDirectory();
    final File target = File('${directory.path}/${asset.name}');

    // A retry after a failed install should not re-fetch tens of megabytes. If a
    // file of exactly the expected size is already there, reuse it; Android
    // verifies the signature at install time, so a corrupt file of the right
    // length cannot be installed by accident.
    if (asset.sizeBytes > 0 &&
        target.existsSync() &&
        target.lengthSync() == asset.sizeBytes) {
      return target;
    }

    await _effectiveDownloader.downloadTo(
      url: asset.downloadUrl,
      target: target,
      headers: <String, String>{
        'Accept': 'application/octet-stream',
        'User-Agent': 'Decanter',
        if (settings.updateToken.trim().isNotEmpty)
          'Authorization': 'Bearer ${settings.updateToken.trim()}',
      },
      onProgress: onProgress,
    );
    return target;
  }

  /// Hands a downloaded APK to the system installer.
  ///
  /// Returns false when the app is not yet permitted to install packages, having
  /// opened the settings screen that grants it — the caller should tell the user
  /// to retry rather than pretending the install started.
  Future<bool> install(File apk) async {
    if (!await canInstallPackages()) {
      await openInstallSettings();
      return false;
    }
    await _channel.invokeMethod<bool>('install', <String, dynamic>{
      'path': apk.path,
    });
    return true;
  }
}
