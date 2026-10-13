# Decanter 0.1.0 — first testable build

The first installable APK. No model backend yet: this build exists to put the
interface and the lorebook engine in your hands so both can be judged on real
hardware.

## What works

**Character cards.** V1, V2 and V3, read from PNG (`chara` / `ccv3` chunks,
with `ccv3` preferred when a card carries both, matching SillyTavern's own
parser) or from JSON. Unmodelled fields survive a re-export instead of being
dropped.

**Lorebooks.** World Info activation with key matching (case sensitivity,
whole-word, regex), secondary keys with all four selective-logic modes, scan
depth, recursion, inclusion groups, sticky / cooldown / delay timing, and a
token budget. Entries route to all eight prompt positions: before and after the
character block, Author's Note top and bottom, in-chat at depth, example-message
top and bottom, and named outlets.

**Prompt assembly.** SillyTavern's fixed block order, with Author's Note and
depth-lore injected into the chat history rather than appended, and the oldest
history dropped first when the context budget is tight.

**The lorebook inspector** — the reason to install this build. Every time you
send a message, the panel shows which entries activated, the keys that matched,
where in the prompt each one lands, and the token cost. Type `furnace`,
`sea glass`, or `the accident` and watch it change.

## The UI

Liquid glass, built from layers rather than a single blur: a frosted backdrop,
a diagonal tint that gives the pane thickness, a rim border where it catches
light, and a specular streak along the top edge. The background image drifts
slowly so the glass has something moving behind it, and a highlight sweeps
across the header.

Deliberately not a blue-purple gradient.

## What is deliberately missing

- **No model backend.** Bring-your-own-key, streaming, and presets are the next
  build. Sending a message currently records it locally and says so.
- **No card importing yet.** One original sample character ships in the app.
- **No refraction.** Real light-bending at the glass edges needs a fragment
  shader sampling the backdrop. The layered approach here is what a shader would
  modulate — this is the shape, not the finished material.
- **No signature.** Signed with the debug key, so it installs on an emulator or
  a device with unknown sources enabled and nothing else.

## Install

Download the APK and either drag it onto a running emulator or use:

```
adb install -r decanter-0.1.0.apk
```

## Verification

129 tests cover the engine, including regression tests run against real
SillyTavern output (`default_Seraphina.png`, `Eldoria.json`) fetched at test
time. 14 tests cover the app layer.

Every check runs in GitHub Actions on each push — formatting, analysis,
and the full suite — and the APK attached here is the artifact that pipeline
produced, not a local build.

It is a universal APK carrying `arm64-v8a`, `armeabi-v7a` and `x86_64`, so it
installs on a phone and on an x86_64 emulator from the same file.

    sha256  81aca90f0aa442e8caad3ff80a515c2bacddd1ecfa565e5ad2c60eafefef7f9e

Built from commit `40ebdeb` by run
https://github.com/kestrelawen/decanter/actions/runs/38411397769

## Credits

This is a clean reimplementation written from the public format specifications
(Character Card V2 and V3), not a port. SillyTavern is AGPL-3.0; no code or
content from it is included here. The sample character and background art are
original to this project.
