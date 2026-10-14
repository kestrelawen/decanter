# Decanter 0.4.0

The app is usable now: a library, card importing, and conversations that survive
being closed. It also fixes the dead settings button.

## Install

Download `decanter-0.4.0.apk` below and open it on the device.

## Fixed: the settings button did nothing

The handler called `Navigator.of(context)` with a context belonging to the State
that *creates* the `MaterialApp` — so it sat above the Navigator and threw
"Navigator operation requested with a context that does not include a Navigator"
on every tap. A release build swallows that, which is why the symptom was a dead
button rather than a crash. The app now holds a `navigatorKey`, and a test taps
the gear and asserts the settings screen opens.

The refresh button was not broken, but it looked it: on a conversation that was
only the opening greeting, resetting changed nothing on screen. It now clears the
saved conversation too, so it visibly does what it says.

## The library

The app opens on your characters instead of a single hardcoded card.

- Every character, with a monogram, lorebook and greeting counts, and a preview
  of the description.
- **CONTINUE** on any character that has a conversation, so you can tell at a
  glance which ones you have already spoken to.
- **IMPORT A CARD** opens the system file picker. A PNG card with the character
  embedded and a `.json` export both work. (A `.charx` archive does not, yet —
  it says so rather than importing junk.)
- Tap a character to open its conversation; long-press or use the bin icon to
  delete it, with a confirmation that says what will be lost.
- The bundled sample character is imported on first run rather than being the
  only card the app could ever show.

## Conversations persist

A conversation is written to disk as each turn settles — not on every streamed
token, which would rewrite the file hundreds of times per reply for nothing.
Reopening a character picks up where you left off. "New chat" clears the saved
copy, so it means new on the next launch rather than resurrecting what it just
discarded.

## Under it

`LibraryStore` lives in `decanter_core` and takes its root directory as an
argument, so the whole storage layer is unit-tested on a machine with no device:

- Writes go to a temporary file and are renamed into place, so a process killed
  mid-write leaves the previous good file rather than a truncated one.
- One unreadable card is skipped, not fatal — it cannot make the rest of your
  library unreachable.
- Cards get readable slug-based directory names (`mira-vance`, `mira-vance-2`),
  so a library is something you can inspect and repair by hand.
- The original file is kept next to the parsed card, so a PNG card's image is
  still recoverable.

Card picking is four methods added to the app's existing Kotlin channel rather
than a new plugin dependency. The picker's copy is deleted once the card is
imported instead of accumulating in the cache.

## Tests

229 in `decanter_core` (from 193) and 37 in the app (from 23). The new app tests
cover the shell, the library, and persistence, including the settings-button
regression.

## Not verified

Everything below the widget layer is unit-tested, but the parts that need a real
device have not been run: the system file picker actually returning a file, and
Android's installer replacing the app. The picker's channel name and the import
path are covered by a mocked-channel test, which catches the failure mode that
would otherwise only appear at runtime.

## Still missing

No card editing, no swipes or regeneration, no multiple conversations per
character, no export. The API key is stored unencrypted in shared preferences.
