import 'package:flutter/services.dart';

/// The channel [MainActivity] answers for library concerns.
///
/// A named constant because a mismatch between this and the Kotlin string
/// compiles cleanly and fails only on a device, as a `MissingPluginException`
/// that does not say which side is wrong.
const String libraryChannelName = 'app.decanter/library';

/// A card file the user picked, already copied into the app's own storage.
///
/// The picker hands back a content:// URI that is only readable while the grant
/// lasts and that Dart cannot open at all, so the platform side materialises the
/// bytes into a real file first.
class PickedCardFile {
  const PickedCardFile({required this.path});

  final String path;

  /// The name the picker reported, used for the library entry.
  String get fileName => path.split('/').last;
}

/// Platform services the library needs: a place to keep files, and a way to get
/// one in.
class LibraryPlatform {
  const LibraryPlatform({
    MethodChannel channel = const MethodChannel(libraryChannelName),
  }) : _channel = channel;

  final MethodChannel _channel;

  /// An app-private directory that survives an app update.
  Future<String> documentsDirectory() async {
    final String? path = await _channel.invokeMethod<String>(
      'documentsDirectory',
    );
    if (path == null || path.isEmpty) {
      throw StateError('The platform returned no documents directory.');
    }
    return path;
  }

  /// Opens the system file picker.
  ///
  /// Returns null when the user backs out, which is a normal outcome rather than
  /// an error to report.
  Future<PickedCardFile?> pickCardFile() async {
    final String? path = await _channel.invokeMethod<String>('pickCardFile');
    if (path == null || path.isEmpty) return null;
    return PickedCardFile(path: path);
  }
}
