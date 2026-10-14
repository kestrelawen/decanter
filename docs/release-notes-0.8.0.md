# Decanter 0.8.0

Phase 3 Multiple Chats & Branching: run multiple independent conversations per character card, branch timelines from any turn, switch between chat threads with previews, and manage your story branches with liquid-glass precision.

## Install

Download `decanter-0.8.0.apk` from GitHub releases or CI artifacts, or let Decanter update itself from the in-app prompt.

## Highlights

- **Multiple Chats per Character**:
  - Tap the new **Chats** icon (`Icons.forum_outlined`) in the character header to open the Conversations sheet.
  - View all stored threads with live message counts, timestamps, snippets, and active checkmarks.
  - Create new threads anytime with **NEW CHAT** without losing existing conversations.
- **Conversation Branching (Forking)**:
  - Branch timelines from any message: open message actions (`...` or long-press) and tap **Branch conversation from here**.
  - Decanter forks history up to that turn into a new thread and switches to it instantly, letting you explore "what if" scenarios without overwriting your original story.
  - Duplicate entire chats directly from the thread action menu.
- **Chat Management**:
  - **Rename threads**: Custom titles to easily identify different storylines or plot branches.
  - **Delete threads**: Safely clean up abandoned branches while leaving other chats intact.
  - **Thread-safe switching**: Current drafts and messages are automatically flushed to disk before switching.
- **Backward Compatibility**:
  - Automatically migrates existing single-chat files (`chats/<card_id>.json`) into threads (`chats/<card_id>/main.json`) with zero data loss.
  - Deleting a character card from your library safely cleans up all associated chat threads.

## Tests

Core suite expanded to 251 tests in `decanter_core` and comprehensive widget tests in `app`, covering thread listing, branching, switching, renaming, deletion, and legacy migration.
