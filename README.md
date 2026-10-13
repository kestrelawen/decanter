# Decanter

An Android client for SillyTavern-compatible character cards, lorebooks and presets.

Name: a decanter is the glass vessel a tavern pours from — liquid glass, a tavern.
Rename is a one-liner if you hate it.

## What this is

A from-scratch Flutter app for Android that reads and writes the SillyTavern
ecosystem's formats and reimplements its core behaviour:

- Character cards — V1, V2, V3, PNG-embedded (`chara` / `ccv3` tEXt chunks), raw JSON
- Character books (lorebooks embedded in a card)
- World Info / lorebooks — native `.json` format
- Personas, Author's Note, prompt assembly
- BYOK backends (bring your own key) with streaming
- Liquid-glass UI: image background, translucent glass surfaces, fluid animation

## Licensing — read this before copying anything

SillyTavern is **AGPL-3.0**. This project is a clean reimplementation written from
the public *format specifications*, not a port of SillyTavern's source:

- Character Card V2 spec — github.com/malfoyslastname/character-card-spec-v2
- Character Card V3 spec — github.com/kwaroran/character-card-spec-v3

Format specs are standards, not code, and implementing them carries no copyleft
obligation. **If any SillyTavern source is ever copied into this repo, the whole
project must become AGPL-3.0.** Keep the reimplementation clean.

## Layout

    packages/decanter_core/   Pure Dart. Card/world-info parsing, prompt assembly.
                              No Flutter import, so it unit-tests with `dart test`.
    app/                      Flutter app (UI, Android target). Built in CI.
    .github/workflows/        Android build + test pipeline.

Logic lives in `decanter_core` rather than in widgets on purpose: the build agent
has no Android SDK locally, so anything that can only run inside Flutter is
unverifiable until CI runs. Pure Dart is testable immediately.

## Build

There is no Android SDK, Java, or Flutter on this machine and no passwordless
sudo to install them. Android artifacts are produced by GitHub Actions and
downloaded from the run. Local verification covers `decanter_core` only:

    cd packages/decanter_core && dart test
