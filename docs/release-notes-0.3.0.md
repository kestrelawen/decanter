# Decanter 0.3.0

Decanter now updates itself, and — more importantly — it can now actually reach
the network in a release build.

## Install

Download `decanter-0.3.0.apk` below and open it on the device. Android will ask
you to allow Decanter to install apps the first time the updater runs.

## Fixed: release builds had no network access

v0.2.0's release APK could not make a single request. Flutter's project template
declares `android.permission.INTERNET` in `src/debug` and `src/profile` only, and
a release build merges `src/main` alone — which declared no permissions at all.
So the chat loop shipped in 0.2.0 would have failed on a real device no matter
what endpoint or key was configured, and nothing in the build output mentioned it.

`INTERNET` is now declared in the release manifest, and CI fails the build if it
ever goes missing again.

## In-app updates

Settings → UPDATES → CHECK asks the GitHub releases API for the latest release and
compares its tag against the version this binary was built from. If it is newer,
the release notes are shown and one tap downloads the APK and hands it to the
Android installer.

- The version is read from `pubspec.yaml` by the build workflow and injected with
  `--dart-define`, so it cannot drift from the release tag it is compared against.
- The download is written to a `.part` file and renamed only after the byte count
  matches the size GitHub declared. A truncated download is refused rather than
  handed to the installer as a corrupt APK.
- Redirects are followed manually, and the `Authorization` header is dropped when
  the redirect changes host. GitHub serves release assets via a 302 to signed
  object storage, which rejects a request carrying both its own signature and our
  token.
- If Android has not granted "install unknown apps", the updater says so and opens
  the right settings screen rather than silently doing nothing. The retry does not
  re-download.

### Private repository note

This repository is private, and GitHub answers **404** for a private repository to
an unauthenticated client — it does not admit the repository exists. So the
updater cannot distinguish "no releases yet" from "not allowed to look", and
neither can you. Paste a read-only token into Settings → UPDATES (the field is
optional and only used for the update check and asset download) or make the
repository public. The error message says this rather than just "not found".

## Also in this release

- The `android/` platform folder is committed instead of generated per build. It
  needed edits a generator cannot express: a permission, a FileProvider, and a
  Kotlin method channel. CI now asserts those are intact before building.
- Version bumped to `0.3.0+3`.

## Not verified

The download-and-install path has not been exercised on a device: it needs a
release whose tag is newer than the installed build, which requires this release
to exist first. The version comparison, release parsing, redirect handling and
truncation guards are covered by unit tests; the Android handoff is not.

## Still missing

No character library or menu, no card importing, no persistence between launches.
The API key is stored unencrypted in shared preferences.
