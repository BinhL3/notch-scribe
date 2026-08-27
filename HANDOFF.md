# Noi — handoff (v0.1.0, 2026-08-27)

A one-page brief for updating the project page / portfolio. Everything here is
in the public repo; download link is the GitHub Release.

## One-liner

**Noi — voice in, finished text out, from the notch.** A macOS dictation app
with a native Dynamic-Island overlay: hold a key, speak, release, and the text
lands where your cursor is. Select text and tap a second key to have it
refined in place. Say "note down…" and it's kept as a note instead of typed.

- Download: https://github.com/BinhL3/noi/releases/tag/v0.1.0 (`Noi_0.1.0_aarch64.dmg`, unsigned)
- Source: https://github.com/BinhL3/noi (MIT, built on Handy)
- Stack: Tauri 2 · Rust · React · Swift (AppKit/CALayer island, SwiftUI inbox) · SQLite

## What shipped in 0.1.0

- **The notch is the UI.** A pure-CALayer island grows out of the camera
  housing with Apple-spec springs; content is revealed by the shape opening.
  On external displays it floats as a small stadium pill; it follows the
  screen you're working on and yields the notch to Alcove / boring.notch.
- **Dictation.** Hold Right ⌥ (any number of alternate keys per action —
  one per keyboard). Live Siri-style wave tracks your voice at 60 Hz.
  Apple Speech (`SpeechAnalyzer`, on-device, macOS 26) is a model in the
  list, ~0.2 s per sentence; Nemotron / Parakeet / Whisper downloadable.
- **Refine on selection.** Tap Right ⌘ → clean up the selection; tap-and-hold
  → speak an instruction, release applies; double-tap → describe until the
  next tap. Plain dictation is never refined.
- **Notes as a byproduct.** "note down / note to self / remember to …" keeps
  the utterance instead of typing it: stored raw at once, refined by your
  model if enabled, put on the clipboard. The island's click-to-expand
  inbox: swipe/circle to clear (check blooms, row slides out), tap to copy,
  "N cleared today". Each note carries its *situation* — frontmost app and,
  in a browser, the page — shown as an app icon + "Safari · github.com".
- **Microphones that follow you.** Preference is a ranked list; the first
  connected mic wins. CoreAudio listener re-resolves on dock/undock.
- **Settings.** Liquid-Glass window, simple single-column page with
  "Advanced ›" for the full Handy settings.

## Suggested site copy

> Noi turns the MacBook notch into a dictation island. Hold a key and talk;
> the text appears where you're typing, refined only when you ask. Say
> "note down…" and it files a note — with the app and page you were on —
> into an inbox that lives in the notch. On-device with Apple Speech; open
> source, built on Handy.

Screenshots worth taking: island at rest / dictating (wave) / "Noted" / the
inbox expanded on the MacBook; the floating pill on an external display;
the Simple settings page.

## Install note for the page

Unsigned build: after dragging to Applications, run
`xattr -d com.apple.quarantine /Applications/Noi.app` or use
System Settings → Privacy & Security → *Open Anyway*. Notarized builds come
with a Developer ID.

## Decisions (why it is the way it is)

- Refine = selection only; dictation stays raw and fast.
- No media player / song banner / volume HUD in the island — built one,
  removed it: copying Alcove isn't the product. Coexist instead.
- No iCloud/file sync; cross-device will be a real backend (Supabase) behind
  a `store` seam; local SQLite stays the source of truth.
- Fewer settings; hide (Simple/Advanced) rather than delete.

## Next

1. Notes as LLM context: write-through markdown mirror `~/Noi/notes/*.md`
   + "copy snippet for CLAUDE.md"; `noi notes list --json` CLI.
2. Smarter note capture: focus-aware (no text field → everything is a
   note), keep-not-divert byproduct notes via an on-device classifier,
   eval-gated.
3. Onboarding "introduce yourself" → custom words; Developer ID +
   notarization; agent layer (intents → actions with undo) → iPhone.

## Build & release

```sh
bun install && bun run tauri dev          # develop
bun run tauri build                        # .dmg in src-tauri/target/release/bundle/dmg
gh release create vX.Y.Z <dmg> -R BinhL3/noi --title "Noi X.Y.Z" --notes-file notes.md
```

If a build fails with a `notch-scribe/handy/...` path, the `target/` cache
predates the folder rename: delete `target/{debug,release}/build/tauri-*`,
`tauri-plugin-*`, `noi-*` and the matching `.fingerprint` entries.
