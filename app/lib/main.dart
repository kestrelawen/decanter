import 'dart:convert';
import 'dart:io';

import 'package:decanter_core/decanter_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

import 'src/library_platform.dart';
import 'src/library_screen.dart';
import 'src/settings.dart';
import 'src/settings_screen.dart';

/// The card shipped in assets, imported on first run so a fresh install has
/// something real to open instead of an empty shelf.
const String _sampleCardAsset = 'assets/cards/mira_vance.json';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final SettingsStore settingsStore = SettingsStore();
  final AppSettings settings = await settingsStore.load();

  final LibraryStore library;
  String? startupError;
  try {
    // The root comes from the platform, because only it knows where this app is
    // allowed to write.
    final String root = await const LibraryPlatform().documentsDirectory();
    library = LibraryStore(Directory('$root/library'))..ensureDirectories();
  } on Object catch (error) {
    // Failing to open storage is worth saying out loud, but not worth refusing to
    // launch over: the app runs from a temporary directory instead so the user
    // can see what happened rather than watching it die before it draws.
    startupError =
        'Could not open a place to save your characters, so nothing will '
        'persist. $error';
    library = LibraryStore(
      Directory('${Directory.systemTemp.path}/decanter-library'),
    )..ensureDirectories();
  }

  await _seedSampleCard(library);

  runApp(
    DecanterApp(
      store: library,
      initialSettings: settings,
      settingsStore: settingsStore,
      startupError: startupError,
    ),
  );
}

/// Imports the bundled card the first time the app runs.
Future<void> _seedSampleCard(LibraryStore library) async {
  try {
    if (library.list().isNotEmpty) return;
    final String raw = await rootBundle.loadString(_sampleCardAsset);
    library.importCard(bytes: utf8.encode(raw), fileName: 'mira_vance.json');
  } on Object {
    // A missing or malformed bundled asset must not stop the app from starting;
    // the library screen still offers an import.
  }
}

class DecanterApp extends StatefulWidget {
  const DecanterApp({
    super.key,
    required this.store,
    required this.initialSettings,
    required this.settingsStore,
    this.startupError,
  });

  final LibraryStore store;
  final AppSettings initialSettings;
  final SettingsStore settingsStore;

  /// Something that went wrong before the first frame, to be shown rather than
  /// swallowed.
  final String? startupError;

  @override
  State<DecanterApp> createState() => _DecanterAppState();
}

class _DecanterAppState extends State<DecanterApp> {
  late AppSettings _settings = widget.initialSettings;

  /// The Navigator is created *inside* `MaterialApp`, so a context belonging to
  /// this State sits above it and has none to find. `Navigator.of(context)` from
  /// here throws "Navigator operation requested with a context that does not
  /// include a Navigator" — which is why the settings button did nothing at all
  /// when tapped, with the failure invisible in a release build.
  ///
  /// This key is the handle to it instead.
  final GlobalKey<NavigatorState> _navigator = GlobalKey<NavigatorState>();

  Future<void> _openSettings() async {
    final NavigatorState? navigator = _navigator.currentState;
    if (navigator == null) return;

    final AppSettings? updated = await navigator.push<AppSettings>(
      MaterialPageRoute<AppSettings>(
        builder: (BuildContext context) => SettingsScreen(initial: _settings),
      ),
    );
    if (updated == null || !mounted) return;

    setState(() => _settings = updated);
    // Persisted after the UI already has the new value: a failed write should
    // not block using what was just typed.
    await widget.settingsStore.save(updated);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Decanter',
      debugShowCheckedModeBanner: false,
      navigatorKey: _navigator,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color.fromRGBO(12, 9, 8, 1),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color.fromRGBO(214, 140, 74, 1),
          brightness: Brightness.dark,
        ),
      ),
      home: LibraryScreen(
        store: widget.store,
        settings: _settings,
        onOpenSettings: _openSettings,
        startupError: widget.startupError,
      ),
    );
  }
}
