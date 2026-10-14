# Decanter 0.7.0

Phase 2 Message Controls: edit turns in place, prune conversations, continue generations seamlessly, and inject narration notes.

## Install

Download `decanter-0.7.0.apk` from GitHub releases or CI artifacts, or let Decanter update itself from the in-app prompt.

## Highlights

- **Message Editing**:
  - Long-press any message bubble to open the actions sheet and tap **Edit message**.
  - Edit user turns, narrator notes, or assistant replies in a rounded glass dialog.
  - When editing assistant turns with multiple swipes, updates the active swipe while preserving all alternate generations.
- **Continue Generation**:
  - When a model stops generating or hits token limits, tap **CONTINUE** right on the assistant message toolbar or in the long-press menu.
  - Tokens stream in real time directly onto the end of the active bubble and persist cleanly.
- **Prune & Delete**:
  - **Delete message**: Remove unwanted turns from history.
  - **Prune from here**: Delete a turn and all messages that follow it with a confirmation prompt, perfect for rolling back stories.
- **Narrator & System Notes**:
  - Type `/note <text>`, `/sys <text>`, or `/narration <text>` in the composer to inject notes without triggering an automatic AI reply.
  - Long-press the send button to toggle between sending as a user message or inserting as a narrator note.
- **Clipboard Copy**:
  - Copy any message's raw text directly from the actions sheet.

## Tests

Core suite expanded to 246 tests in `decanter_core` and 52 tests in `app`, covering edit, continue, prune, note injection, and UI gesture interactions.
