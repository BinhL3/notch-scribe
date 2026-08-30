# Noi — site brief

Everything an agent needs to build a project page for Noi. Assets referenced
here live in this repo under `docs/`. Facts below are current as of v0.1.0
(2026-08-29); check `HANDOFF.md` for the state of the codebase.

## The product in one breath

**Noi — voice in, finished text out, from the notch.**

A macOS dictation app whose entire UI is a Dynamic Island living in the
MacBook notch. Hold a key, speak, let go: the words land where your cursor
is. Select text and tap a second key to have it cleaned up in place — or hold
and say what to change. Say "note down…" and it's filed as a note instead of
typed. On-device speech by default. Open source, built on Handy.

## Links

- Download (macOS, Apple Silicon): https://github.com/BinhL3/noi/releases/latest
  — the `.dmg`; in-app updates from then on.
- Source: https://github.com/BinhL3/noi (MIT)
- Foundation: https://github.com/cjpais/Handy (credit "built on Handy")

## Audience & tone

People who write all day on a Mac and would rather talk: developers,
writers, founders. Tone: quiet, precise, Apple-adjacent — short sentences,
no exclamation marks, no "revolutionary". Show the island; don't describe it.

## Feature list (use these words)

1. **The notch is the UI.** A native island grows out of the camera housing
   — one spring, content revealed by the shape opening, hover to peek. On an
   external display it floats as a small pill at the top. Pure AppKit, no
   webview.
2. **Hold a key, talk.** Right ⌥ by default. Add another key for a second
   keyboard. A live Siri-style wave tracks your voice.
3. **On-device by default.** Apple Speech (macOS 26) transcribes with nothing
   to download, ~0.2 s for a sentence. Nemotron, Parakeet and Whisper are one
   click away.
4. **Refine on selection.** Select text, tap Right ⌘ to clean it up;
   tap-and-hold to say what to change ("make this a list", "shorter"). Plain
   dictation is never touched.
5. **Notes as a byproduct.** Start with "note down…" and it's kept, not typed.
   Click the island for the inbox: swipe to clear, tap to copy. Each note
   remembers the app and page you were on.
6. **Bring your own model.** Refine with an API key (OpenAI-compatible) or
   Ollama locally. Nothing leaves the Mac unless you choose a cloud model.
7. **Plays nicely.** Yields the notch to Alcove or boring.notch if they're
   running. In-app updates. Microphones follow you when you dock.

## Copy blocks

Hero:
> **Noi**
> Voice in, finished text out — from the notch.
> Hold a key and talk. The words land where you're typing.
> [Download for Mac]  ·  Open source

Sub-hero (three columns):
> **The notch is the UI** — A native island, one spring, nothing to open.
> **On-device** — Apple Speech, ~0.2 s a sentence, nothing to download.
> **Refine, don't rewrite** — Select, tap, say what to change.

Notes section:
> Say "note down…" and Noi keeps it instead of typing it — with the app and
> page you were on. Your inbox lives in the notch.

Footer line:
> Open source (MIT). Built on Handy. Made by Binh Le.

## Visuals

`docs/screenshots/` (2× Retina PNGs, dark mode):

| file | shows | use |
|---|---|---|
| `island-dictating.png` | island open from the notch, wave, "Work" is unrelated background | hero (crop to the island) |
| `island-notes.png` | island expanded on the notes inbox, "All clear" state | notes section |
| `settings-simple.png` | the Simple settings page in the Liquid Glass window (pre-polish; retake if possible) | "few settings" |

Retake list if the page needs more (requires a person to press keys):
island at rest (invisible on the notch — show the external-display pill
instead), "Noted" green check, the notes inbox with 3 notes showing app
icons, the refine "Describe the change" hint.

`docs/brand/`:

- `noi-mark.svg` — the wave mark (150×150 viewBox, light-blue gradient).
  Use on dark backgrounds; it is the same wave the island shows while
  dictating.
- `noi-icon-1024.png` — macOS app icon (rounded square, with the mark).
- `noi-logo-1024.png` — mark alone, square, transparent.

Wordmark: "Noi" in the system font (SF Pro / -apple-system), semibold, next
to the mark at ~0.42× the wordmark width. See
`src/components/icons/NoiWordmark.tsx` for the exact ratio.

## Colours (from `src/styles/theme.css`)

| token | light | dark | use |
|---|---|---|---|
| accent (`logo-primary`) | `#6fa8dc` | `#9fc5e8` | links, toggles, the mark |
| background | `#fbfbfb` | `#2c2b29` | page |
| text | `#0f0f0f` | `#fbfbfb` | body |
| mid-gray | `#808080` | `#808080` | secondary text |
| island | `#000000` | — | the island is always pure black |
| assistant purple | `rgb(194,168,245)` (`#c2a8f5`) | — | refine/instruct states only |

Dictation wave palette (three layered blues, screen-blended):
`rgba(112,168,219,.85)`, `rgba(158,196,232,.75)`, `rgba(230,245,255,.65)`.

Rules: one accent; purple only for assistant states; no glow or outline
chrome; black island on any background. Dark page preferred — the product
is black-on-black.

## Install text (keep verbatim until the build is notarized)

> Requires macOS 26 on Apple Silicon. Open the `.dmg`, drag Noi to
> Applications. The build is unsigned: on first launch, run
> `xattr -d com.apple.quarantine /Applications/Noi.app` or use
> System Settings → Privacy & Security → *Open Anyway*. Updates arrive
> in-app after that.

## FAQ (short answers)

- **Does audio leave my Mac?** Not for transcription with Apple Speech or a
  downloaded model. Refine sends the *selected text* to whatever model you
  configured — including Ollama, which is local.
- **Which key?** Right ⌥ to dictate, Right ⌘ to refine; both changeable, and
  you can add a second key per action for another keyboard.
- **No notch?** The island floats at the top of the screen instead.
- **Intel Macs?** Not yet; Apple Silicon only.
- **Price?** Free, MIT.

## Don'ts

- Don't call it a "Dynamic Island clone" or compare with Alcove; it isn't a
  media/notch utility — it's dictation.
- Don't promise iPhone, sync, or an agent layer; those are roadmap.
- Don't show the settings page as the hero; the island is the product.
