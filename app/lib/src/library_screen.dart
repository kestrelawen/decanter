import 'dart:io';

import 'package:decanter_core/decanter_core.dart';
import 'package:flutter/material.dart';

import 'glass.dart';
import 'home_screen.dart';
import 'library_platform.dart';
import 'settings.dart';

/// The app's front door: every character you have, and a way to add one.
class LibraryScreen extends StatefulWidget {
  const LibraryScreen({
    super.key,
    required this.store,
    required this.settings,
    required this.onOpenSettings,
    this.platform = const LibraryPlatform(),
    this.startupError,
  });

  final LibraryStore store;
  final AppSettings settings;
  final Future<void> Function() onOpenSettings;
  final LibraryPlatform platform;

  /// A failure from before the first frame, shown until the user dismisses it.
  final String? startupError;

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  late List<LibraryEntry> _entries;

  String? _notice;
  late String? _error = widget.startupError;
  bool _importing = false;

  @override
  void initState() {
    super.initState();
    _entries = widget.store.list();
  }

  void _refresh() {
    if (!mounted) return;
    setState(() => _entries = widget.store.list());
  }

  Future<void> _import() async {
    if (_importing) return;
    setState(() {
      _importing = true;
      _error = null;
      _notice = null;
    });

    String? copiedPath;
    try {
      final PickedCardFile? picked = await widget.platform.pickCardFile();
      if (picked == null) {
        // Cancelled. Nothing to report and nothing to apologise for.
        if (mounted) setState(() => _importing = false);
        return;
      }
      copiedPath = picked.path;

      final LibraryEntry entry = widget.store.importCard(
        bytes: File(picked.path).readAsBytesSync(),
        fileName: picked.fileName,
      );

      if (!mounted) return;
      setState(() {
        _importing = false;
        _notice = 'Imported ${entry.name}.';
        _entries = widget.store.list();
      });
    } on CardFormatException catch (error) {
      // The expected failure: a file that is not a card. The message from the
      // parser already names what was wrong, so it is shown as-is.
      if (mounted) {
        setState(() {
          _importing = false;
          _error = error.message;
        });
      }
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _importing = false;
          _error = 'Could not import that file: $error';
        });
      }
    } finally {
      // The picker's copy exists only to get the bytes across; leaving it behind
      // would grow the cache by a card-sized file per import.
      if (copiedPath != null) {
        final File copy = File(copiedPath);
        if (copy.existsSync()) copy.deleteSync();
      }
    }
  }

  Future<void> _open(LibraryEntry entry) async {
    final TavernCard card;
    try {
      card = widget.store.loadCard(entry.id);
    } on Object catch (error) {
      setState(() => _error = 'Could not open ${entry.name}: $error');
      return;
    }

    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => HomeScreen(
          card: card,
          settings: widget.settings,
          onOpenSettings: widget.onOpenSettings,
          store: widget.store,
          entryId: entry.id,
        ),
      ),
    );

    // A conversation may have started while that screen was open, which changes
    // whether this row offers NEW or CONTINUE.
    _refresh();
  }

  Future<void> _confirmDelete(LibraryEntry entry) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        backgroundColor: const Color.fromRGBO(26, 18, 15, 1),
        title: Text(
          'Delete ${entry.name}?',
          style: const TextStyle(color: Glass.textPrimary, fontSize: 16),
        ),
        content: const Text(
          'The character and its conversation are removed from this device. '
          'This cannot be undone.',
          style: TextStyle(
            color: Glass.textSecondary,
            fontSize: 13,
            height: 1.45,
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;
    widget.store.delete(entry.id);
    if (!mounted) return;
    setState(() {
      _entries = widget.store.list();
      _notice = 'Deleted ${entry.name}.';
      _error = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color.fromRGBO(12, 9, 8, 1),
      body: LiquidBackground(
        image: const AssetImage('assets/background.png'),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 0),
            child: Column(
              children: <Widget>[
                _header(),
                const SizedBox(height: 10),
                Expanded(child: _body()),
                if (_notice != null) ...<Widget>[
                  const SizedBox(height: 8),
                  _banner(_notice!, bad: false),
                ],
                if (_error != null) ...<Widget>[
                  const SizedBox(height: 8),
                  _banner(_error!, bad: true),
                ],
                const SizedBox(height: 12),
                _importBar(),
                const SizedBox(height: 12),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _header() {
    return GlassPanel(
      padding: const EdgeInsets.fromLTRB(16, 12, 10, 12),
      child: SheenSweep(
        child: Row(
          children: <Widget>[
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    'DECANTER',
                    style: TextStyle(
                      color: Glass.textPrimary,
                      fontSize: 16.5,
                      letterSpacing: 2.4,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  SizedBox(height: 2),
                  Text(
                    'characters',
                    style: TextStyle(
                      color: Glass.textFaint,
                      fontSize: 10.5,
                      letterSpacing: 0.4,
                    ),
                  ),
                ],
              ),
            ),
            GlassIconButton(
              icon: Icons.tune_rounded,
              onTap: () => widget.onOpenSettings(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _body() {
    if (_entries.isEmpty) return _emptyState();

    return ListView.builder(
      padding: const EdgeInsets.only(top: 2, bottom: 4),
      itemCount: _entries.length,
      itemBuilder: (BuildContext context, int index) => _row(_entries[index]),
    );
  }

  Widget _emptyState() {
    return const Center(
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.local_cafe_outlined, size: 38, color: Glass.textFaint),
            SizedBox(height: 14),
            Text(
              'The decanter is empty',
              style: TextStyle(
                color: Glass.textPrimary,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
            SizedBox(height: 8),
            Text(
              'Import a character card to begin. A PNG card with the character '
              'embedded and a .json export both work — the file picker is below.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Glass.textFaint,
                fontSize: 12,
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(LibraryEntry entry) {
    final bool hasChat = widget.store.hasChat(entry.id);

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: GestureDetector(
        onTap: () => _open(entry),
        onLongPress: () => _confirmDelete(entry),
        child: GlassPanel(
          radius: 22,
          padding: const EdgeInsets.fromLTRB(15, 13, 10, 13),
          tintStrength: 0.95,
          shadow: false,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              _avatar(entry),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Flexible(
                          child: Text(
                            entry.name,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Glass.textPrimary,
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        if (hasChat) ...<Widget>[
                          const SizedBox(width: 8),
                          _chip('CONTINUE'),
                        ],
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      <String>[
                        if (entry.creator.trim().isNotEmpty) entry.creator,
                        if (entry.loreCount > 0) '${entry.loreCount} lore',
                        if (entry.hasAlternateGreetings)
                          '${entry.greetingCount} greetings',
                      ].join('  ·  '),
                      style: const TextStyle(
                        color: Glass.textFaint,
                        fontSize: 10.5,
                      ),
                    ),
                    if (entry.preview.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 6),
                      Text(
                        entry.preview,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Glass.textSecondary,
                          fontSize: 12,
                          height: 1.4,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 6),
              GlassIconButton(
                icon: Icons.delete_outline_rounded,
                size: 15,
                tintStrength: 0.9,
                onTap: () => _confirmDelete(entry),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// The character's own picture when the card came with one, initials when it
  /// did not.
  Widget _avatar(LibraryEntry entry) {
    final File? picture = widget.store.imageFile(entry.id);
    if (picture == null) return _monogram(entry);

    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: Image.file(
        picture,
        width: 56,
        height: 56,
        fit: BoxFit.cover,
        // Card art is often over a thousand pixels across. Decoding it at full
        // size for a 56px thumbnail would allocate megabytes per row.
        cacheWidth: 168,
        // A file that has gone missing falls back rather than showing a broken
        // image icon in the middle of the shelf.
        errorBuilder:
            (BuildContext context, Object error, StackTrace? stackTrace) =>
                _monogram(entry),
      ),
    );
  }

  Widget _monogram(LibraryEntry entry) {
    final String initials = entry.name
        .split(RegExp(r'\s+'))
        .where((String word) => word.isNotEmpty)
        .take(2)
        .map((String word) => word.substring(0, 1).toUpperCase())
        .join();

    return GlassPanel(
      radius: 999,
      blur: 14,
      padding: EdgeInsets.zero,
      tintStrength: 1.3,
      shadow: false,
      child: SizedBox(
        width: 44,
        height: 44,
        child: Center(
          child: Text(
            initials.isEmpty ? '?' : initials,
            style: const TextStyle(
              color: Glass.textPrimary,
              fontWeight: FontWeight.w600,
              fontSize: 15,
            ),
          ),
        ),
      ),
    );
  }

  Widget _chip(String label) {
    return GlassPanel(
      radius: 99,
      blur: 8,
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      tintStrength: 1.5,
      shadow: false,
      showSpecular: false,
      child: Text(
        label,
        style: const TextStyle(
          color: Glass.textPrimary,
          fontSize: 8.5,
          letterSpacing: 1,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget _banner(String message, {required bool bad}) {
    return GlassPanel(
      padding: const EdgeInsets.fromLTRB(14, 11, 12, 11),
      tintStrength: 1.1,
      borderStrength: 1.4,
      child: Row(
        children: <Widget>[
          Icon(
            bad ? Icons.error_outline_rounded : Icons.check_circle_outline,
            size: 15,
            color: Glass.textSecondary,
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(
                color: Glass.textSecondary,
                fontSize: 11.5,
                height: 1.4,
              ),
            ),
          ),
          GestureDetector(
            onTap: () => setState(() {
              _notice = null;
              _error = null;
            }),
            child: const Padding(
              padding: EdgeInsets.only(left: 8),
              child: Icon(
                Icons.close_rounded,
                size: 15,
                color: Glass.textFaint,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _importBar() {
    return GestureDetector(
      onTap: _importing ? null : _import,
      child: GlassPanel(
        padding: const EdgeInsets.symmetric(vertical: 15),
        tintStrength: _importing ? 0.9 : 2.0,
        child: Center(
          child: _importing
              ? const SizedBox(
                  height: 16,
                  width: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text(
                  'IMPORT A CARD',
                  style: TextStyle(
                    color: Glass.textPrimary,
                    fontSize: 12,
                    letterSpacing: 1.8,
                    fontWeight: FontWeight.w600,
                  ),
                ),
        ),
      ),
    );
  }
}
