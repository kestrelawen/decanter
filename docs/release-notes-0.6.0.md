# Decanter 0.6.0

Swipes and regeneration: navigate alternative generations, regenerate responses, and swipe between multiple greetings.

## Install

Download `decanter-0.6.0.apk` from GitHub releases or CI artifacts, or let 0.5.0 update itself.

## Swipes and regeneration

You can now generate alternative replies, cycle between past generations, and regenerate responses at any time.

- **Swipe toolbar**: Assistant messages now display a clean, unobtrusive glass toolbar showing `< current/total >`.
- **Regenerate button**: Tap `RETRY` on the latest assistant message to generate an alternative reply. The new reply streams in-place and is appended as a new swipe candidate.
- **Horizontal swipe gestures**: Swipe horizontally across any assistant message bubble (drag left for next swipe/regenerate, drag right for previous swipe).
- **Multiple greetings**: Card alternate greetings are seamlessly seeded as opening swipes. You can swipe between greetings directly on the opening bubble or tap the header.
- **Swipe deletion**: Unwanted generations can be deleted with the delete icon, preserving preferred alternatives.
- **Full persistence**: Swipes and the currently selected swipe index are persisted to disk and survive app restarts. Compatible with SillyTavern's `swipes` and `swipe_id` chat format.

## Tests

253 in `decanter_core` (from 246) and 49 in the app (from 45). New tests cover swipe navigation, regeneration prompt assembly, swipe deletion, and UI swipe counter controls.
