# Decanter 0.6.1

Connection resilience and in-text markdown image rendering: robust SSE socket closure handling for OpenAI-compatible reverse proxies and rich roleplay formatting.

## Install

Download `decanter-0.6.1.apk` from GitHub releases or CI artifacts, or let 0.6.0 update itself.

## Highlights

- **Connection dropout resilience**: Solves trailing error banners (`HttpException: Connection closed while receiving data`) on reverse proxies such as `gpurouter.io`, OpenRouter, and local LLM endpoints that terminate the TCP socket after streaming finishes without cleanly closing HTTP chunked encoding. When response content has already arrived, Decanter safely concludes the assistant turn.
- **In-text markdown images**: Supports inline images formatted as `![alt](url)` or `![](www.domain.com/path.jpg)`.
  - Automatically prepends `https://` for protocol-relative or schemeless URLs.
  - Displays sleek liquid-glass image cards with loading indicators and error fallbacks.
  - Tap any image to open an interactive full-screen viewer with zoom and pan support.
- **Roleplay formatting**: Styled roleplay actions (`*whispers softly*`) in subtle italics and bold markers (`**emphasis**`) using the liquid-glass theme typography.

## Tests

Core suite verified with 244 tests passing locally, plus new widget tests in `app/test/app_test.dart` for rich text and image parsing.
