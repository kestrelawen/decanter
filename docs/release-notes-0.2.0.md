# Decanter 0.2.0 — the chat loop works

This build talks to a model. Bring your own key, point it at any
OpenAI-compatible endpoint, and the conversation actually happens.

## What's new

**Bring your own key.** A settings screen with one-tap presets for OpenAI,
OpenRouter, DeepSeek, Groq, Ollama and LM Studio. Any endpoint speaking the
standard `/chat/completions` shape also works — vLLM, llama.cpp, text-generation-webui.

**Streaming replies.** The reply arrives token by token into a glass bubble, with
a stop button that genuinely cancels the request rather than just hiding the
output.

**Your saved prompt is the prompt.** The assembled request goes out in
SillyTavern's block order, with the card's description, personality and scenario,
the lorebook entries that activated this turn, your Author's Note at its
configured depth, and post-history instructions last. The lorebook readout shows
the exact block list and the token cost of each one.

**Errors that explain themselves.** A rejected key, a wrong URL, a missing model
and a provider outage are four different messages, because they need four
different fixes.

**An app icon.** A stoppered decanter, generated from geometry rather than
imported, with adaptive-icon layers so it survives any launcher mask.

**The lorebook readout moved.** It used to sit permanently along the bottom of
the screen, taking vertical space from the conversation it was describing. It is
behind the header button now.

## What's still missing

- **One card.** The bundled sample character, plus a way to switch between its
  two opening greetings. Importing your own cards is the next build.
- **No character library or chat list.** One conversation at a time; nothing is
  persisted between launches yet.
- **No in-app update check.** For now, new builds are downloaded from this page.
- **The API key is stored unencrypted** in Android's shared preferences. That
  matches most BYOK clients, but it is not encrypted at rest.
- **No refraction.** The glass is four layered surfaces, not a shader bending the
  backdrop.

## Install

```
adb install -r decanter-0.2.0.apk
```

Universal APK: `arm64-v8a`, `armeabi-v7a` and `x86_64`, so it installs on a phone
and on a standard x86_64 emulator from the same file. Debug-signed, so enable
unknown sources on a physical device.

## Verification

154 tests cover the engine — card parsing, lorebook activation, prompt assembly,
and the streaming HTTP client, including malformed SSE and a provider that never
sends its terminator. 20 more cover the app: the chat loop, cancellation,
error mapping, and a regression test asserting the lorebook panel really is gone
from the bottom of the layout.

Every check runs in GitHub Actions; the APK attached here is the artifact that
pipeline produced.

    commit   b9ee3213eff1bf01424019a98f3fd240394a2145
    run      https://github.com/kestrelawen/decanter/actions/runs/38421982155
    sha256   81eb368cab4785997c4c630390cfc78784038ae24f88b35c9752ff01cc6621b5

The icon and its adaptive layers are in the package: the release resource
optimiser shortens resource paths, so `res/mipmap-xxxhdpi/ic_launcher.png`
appears as `res/XX.png`, but `resources.arsc` carries `ic_launcher`,
`ic_launcher_background` and `ic_launcher_foreground`.
