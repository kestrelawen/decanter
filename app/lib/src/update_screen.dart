import 'dart:io';

import 'package:decanter_core/decanter_core.dart';
import 'package:flutter/material.dart';

import 'glass.dart';
import 'settings.dart';
import 'update_service.dart';

/// Checks GitHub for a newer build and installs it without leaving the app.
class UpdateScreen extends StatefulWidget {
  const UpdateScreen({super.key, required this.settings});

  final AppSettings settings;

  @override
  State<UpdateScreen> createState() => _UpdateScreenState();
}

class _UpdateScreenState extends State<UpdateScreen> {
  final UpdateService _service = UpdateService();

  UpdateProgress _state = const UpdateProgress(phase: UpdatePhase.idle);
  File? _apk;
  bool _installAllowed = true;

  @override
  void initState() {
    super.initState();
    _refreshPermission();
  }

  @override
  void dispose() {
    _service.dispose();
    super.dispose();
  }

  Future<void> _refreshPermission() async {
    final bool allowed = await _service.canInstallPackages();
    if (!mounted) return;
    setState(() => _installAllowed = allowed);
  }

  Future<void> _check() async {
    setState(
      () => _state = const UpdateProgress(
        phase: UpdatePhase.checking,
        message: 'Asking GitHub for the latest release…',
      ),
    );

    final UpdateCheck check = await _service.checkForUpdate(widget.settings);
    if (!mounted) return;

    setState(() {
      _apk = null;
      if (check.hasUpdate) {
        _state = UpdateProgress(
          phase: UpdatePhase.updateAvailable,
          release: check.release,
          message: check.message,
        );
      } else {
        _state = UpdateProgress(
          phase: check.status == UpdateStatus.failed
              ? UpdatePhase.failed
              : UpdatePhase.idle,
          release: check.release,
          message: check.message,
        );
      }
    });
  }

  Future<void> _downloadAndInstall() async {
    final AppRelease? release = _state.release;
    if (release == null) return;

    try {
      File? apk = _apk;
      if (apk == null) {
        setState(
          () => _state = _state.copyWith(
            phase: UpdatePhase.downloading,
            message: '',
            received: 0,
            total: 0,
          ),
        );

        apk = await _service.downloadUpdate(
          release,
          settings: widget.settings,
          onProgress: (int received, int total) {
            if (!mounted) return;
            setState(
              () => _state = _state.copyWith(
                phase: UpdatePhase.downloading,
                received: received,
                total: total,
              ),
            );
          },
        );
        _apk = apk;
      }

      if (!mounted) return;
      setState(
        () => _state = _state.copyWith(
          phase: UpdatePhase.installing,
          message: 'Handing the file to Android…',
        ),
      );

      final bool started = await _service.install(apk);
      if (!mounted) return;

      setState(() {
        if (started) {
          _state = _state.copyWith(
            phase: UpdatePhase.idle,
            message: 'The installer is open — confirm there to finish.',
          );
        } else {
          // The download is already done, so a retry must not repeat it.
          _state = _state.copyWith(
            phase: UpdatePhase.updateAvailable,
            message: 'Android needs permission before Decanter can install an '
                'app. Allow it, come back, and tap INSTALL — the file is '
                'already downloaded.',
          );
        }
      });
      await _refreshPermission();
    } on Object catch (error) {
      if (!mounted) return;
      setState(
        () => _state = _state.copyWith(
          phase: UpdatePhase.failed,
          message: '$error',
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color.fromRGBO(12, 9, 8, 1),
      body: LiquidBackground(
        image: const AssetImage('assets/background.png'),
        child: SafeArea(
          child: Column(
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 0),
                child: GlassPanel(
                  padding: const EdgeInsets.fromLTRB(16, 14, 10, 14),
                  child: Row(
                    children: <Widget>[
                      const Expanded(
                        child: Text(
                          'UPDATES',
                          style: TextStyle(
                            color: Glass.textPrimary,
                            fontSize: 13,
                            letterSpacing: 1.6,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      _IconAction(
                        icon: Icons.close_rounded,
                        onTap: () => Navigator.of(context).pop(),
                      ),
                    ],
                  ),
                ),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 16),
                  children: <Widget>[
                    _versionCard(),
                    const SizedBox(height: 12),
                    if (_state.release != null &&
                        _state.phase == UpdatePhase.updateAvailable)
                      _releaseCard(_state.release!),
                    if (_state.release != null &&
                        _state.phase == UpdatePhase.updateAvailable)
                      const SizedBox(height: 12),
                    if (_state.message.isNotEmpty) _statusCard(),
                    if (_state.phase == UpdatePhase.downloading)
                      const SizedBox(height: 12),
                    if (_state.phase == UpdatePhase.downloading)
                      _progressCard(),
                    const SizedBox(height: 14),
                    _actionBar(),
                    const SizedBox(height: 14),
                    const Text(
                      'Updates come from the GitHub releases API of the '
                      'repository below. Nothing is uploaded, and the file is '
                      'checked against the size GitHub reports before Android '
                      'is asked to install it.',
                      style: TextStyle(
                        color: Glass.textFaint,
                        fontSize: 11,
                        height: 1.45,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _versionCard() {
    return _card(
      title: 'INSTALLED',
      children: <Widget>[
        Row(
          children: <Widget>[
            Text(
              'Decanter $appVersion',
              style: const TextStyle(
                color: Glass.textPrimary,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
            const Spacer(),
            Text(
              _installAllowed ? 'ready to install' : 'permission needed',
              style: TextStyle(
                color: _installAllowed ? Glass.textFaint : Glass.tint(0.95),
                fontSize: 11,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          widget.settings.updateRepo,
          style: const TextStyle(color: Glass.textFaint, fontSize: 11.5),
        ),
      ],
    );
  }

  Widget _releaseCard(AppRelease release) {
    final ReleaseAsset? asset = release.apk;
    final String size = asset == null || asset.sizeBytes <= 0
        ? ''
        : ' · ${(asset.sizeBytes / 1048576).toStringAsFixed(1)} MB';

    return _card(
      title: 'AVAILABLE',
      children: <Widget>[
        Text(
          '${release.title}$size',
          style: const TextStyle(
            color: Glass.textPrimary,
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
        if (release.notes.trim().isNotEmpty) ...<Widget>[
          const SizedBox(height: 10),
          // Release notes are markdown, and this is not a markdown renderer.
          // Showing them verbatim beats showing nothing.
          Text(
            release.notes.trim(),
            style: const TextStyle(
              color: Glass.textSecondary,
              fontSize: 12,
              height: 1.5,
            ),
          ),
        ],
      ],
    );
  }

  Widget _statusCard() {
    final bool bad = _state.phase == UpdatePhase.failed;
    return _card(
      title: bad ? 'PROBLEM' : 'STATUS',
      children: <Widget>[
        Text(
          _state.message,
          style: TextStyle(
            color: bad ? Glass.tint(1.1) : Glass.textSecondary,
            fontSize: 12.5,
            height: 1.5,
          ),
        ),
      ],
    );
  }

  Widget _progressCard() {
    final double? fraction = _state.fraction;
    final String received = (_state.received / 1048576).toStringAsFixed(1);
    final String total = _state.total > 0
        ? '${(_state.total / 1048576).toStringAsFixed(1)} MB'
        : 'unknown size';

    return _card(
      title: 'DOWNLOADING',
      children: <Widget>[
        Text(
          '$received MB of $total',
          style: const TextStyle(color: Glass.textSecondary, fontSize: 12.5),
        ),
        const SizedBox(height: 10),
        ClipRRect(
          borderRadius: BorderRadius.circular(999),
          child: LinearProgressIndicator(
            value: fraction,
            minHeight: 5,
            backgroundColor: Glass.tint(0.16),
            valueColor: AlwaysStoppedAnimation<Color>(Glass.tint(0.95)),
          ),
        ),
      ],
    );
  }

  Widget _actionBar() {
    final bool busy = _state.phase == UpdatePhase.checking ||
        _state.phase == UpdatePhase.downloading ||
        _state.phase == UpdatePhase.installing;

    final String label;
    if (_state.phase == UpdatePhase.updateAvailable) {
      label = _apk == null ? 'DOWNLOAD & INSTALL' : 'INSTALL';
    } else {
      label = 'CHECK FOR UPDATES';
    }

    final VoidCallback? action = busy
        ? null
        : (_state.phase == UpdatePhase.updateAvailable
            ? _downloadAndInstall
            : _check);

    return GestureDetector(
      onTap: action,
      child: GlassPanel(
        padding: const EdgeInsets.symmetric(vertical: 15),
        tintStrength: busy ? 0.9 : 2.0,
        child: Center(
          child: busy
              ? const SizedBox(
                  height: 16,
                  width: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(
                  label,
                  style: const TextStyle(
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

  Widget _card({required String title, required List<Widget> children}) {
    return GlassPanel(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      tintStrength: 0.85,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            title,
            style: const TextStyle(
              color: Glass.textSecondary,
              fontSize: 10.5,
              letterSpacing: 1.4,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 12),
          ...children,
        ],
      ),
    );
  }
}

/// A circular glass button holding a single icon.
class _IconAction extends StatelessWidget {
  const _IconAction({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: GlassPanel(
        radius: 999,
        blur: 12,
        padding: const EdgeInsets.all(9),
        tintStrength: 1.4,
        shadow: false,
        showSpecular: false,
        child: Icon(icon, size: 17, color: Glass.textPrimary),
      ),
    );
  }
}
