# Decanter 0.5.0

Sending works again, the model list is a button, and your characters' art is
actually used.

## Install

Download `decanter-0.5.0.apk` below and open it on the device, or let 0.4.0
update itself.

## Fixed: sending a message failed instantly

The symptom was `Invalid argument(s): No host specified in URI`, thrown within
milliseconds of tapping send — before anything could have reached the network.

The base URL was being tidied (trailing slashes removed, a stray
`/chat/completions` stripped) but never given a scheme. A URL like

    api.deepseek.com/v1

parses as a *relative* reference with no host at all, and `HttpClient` refuses
it outright. Worse, `localhost:11434` parses as scheme `localhost`, so an
obvious-looking local endpoint fails the same way.

A missing scheme is now supplied:

- `https://` by default.
- `http://` for an address that is genuinely on your own network — `localhost`,
  `127.0.0.1`, `10.x`, `192.168.x`, `172.16-31.x`, `*.local`.

That last part needed a real IPv4 check rather than a prefix match, because
`10.example.com` is a perfectly ordinary domain and forcing it onto http would
break it.

If a URL still has no host after all that, you now get "The base URL has no host
(…). Include the scheme, for example https://api.openai.com/v1" instead of
"Invalid argument(s)".

## Fetch models

Settings → ENDPOINT → the **FETCH** button next to the model name asks your
endpoint what it serves and offers the list. Tapping one fills the field.

Model names are the field people get wrong, and every OpenAI-compatible server
answers `GET /models`. The parser accepts the shapes proxies actually return
(objects under `data`, or bare strings) and treats an unusable payload as "no
models" — with a note to type the name in — rather than letting it look like the
endpoint is broken. A rejected key still says so, using the same wording as the
chat screen.

## Character art

The picture was always being stored on import; nothing had ever read it. Now:

- **The library shows it.** A card imported from a PNG shows its artwork in the
  row instead of initials. A card with no picture — a `.json` export — still
  falls back to initials, which is normal rather than a failure.
- **The chat is set against it.** The character's own art is the backdrop while
  you talk to them, with a heavier scrim than the generated one, because a
  portrait is far busier than the backdrop the app ships with.

Thumbnails decode at display size rather than full resolution: card art is often
over a thousand pixels across, and a 56px thumbnail of it would otherwise
allocate megabytes per row.

## Tests

246 in `decanter_core` (from 229) and 45 in the app (from 37). The new ones cover
the base-URL repair including its boundary cases, `/models` parsing and failure
modes, and the picture path end to end — the library row test fails if the
monogram is drawn for a card that has art.

The fetch button is tested against an injected transport, so the feature is
covered without a network.

## Not verified

The same device-only gaps as before: the system file picker returning a file, and
Android's installer replacing the app. Everything above the widget layer is
unit-tested.

## Still missing

No card editing, no swipes or regeneration, no multiple conversations per
character, no export. The API key is stored unencrypted in shared preferences.
