# GifPaste

A minimal standalone GIPHY search for macOS. Press ⌃⌥G, search, press ↵, and the GIF is pasted into the app you were typing in.
Simplified from the Raycast "GIF Search" extension (MIT): GIPHY only, no favorites, recents, or other providers.

## Install

```bash
brew install isibeni/tap/gifpaste
```

1. Enter a GIPHY API key when prompted. Get a free one at developers.giphy.com (Create an API Key → API). The same dialog offers "Launch at login" (macOS 13+).
2. Allow GifPaste under System Settings → Privacy & Security → Accessibility. This lets it send ⌘V. Without it, the GIF is only copied and you press ⌘V yourself.

Update with `brew upgrade`.

## Development

Requires the Xcode Command Line Tools (`xcode-select --install`).

- `scripts/build.sh dev` builds "GifPaste Dev" and starts it from `/Applications`. It has its own settings, API key and login item, uses ⌃⌥⇧G and shows "DEV" in the menu bar, so it runs next to the Homebrew version.
- `scripts/build.sh install` builds the regular app into `/Applications`. That replaces the Homebrew copy, so run `brew uninstall gifpaste` first.
- Releases are automatic: see `AGENTS.md` for the commit convention.

## Use

| Key | Action |
|---|---|
| ⌃⌥G (default) | Open/close the search |
| ↑ ↓ ← → | Select a GIF |
| ↵ | Paste into the previous app |
| ⌘↵ | Copy only |
| Esc | Close |

An empty search shows trending GIFs. Clicking a GIF also pastes it.

The GIF is pasted as a file named after your search term (for example `thumbs up`). Slack and similar apps show that name next to the GIF. Trending GIFs use their GIPHY title instead. By default the name has no ".gif" (e.g. `thumbs up`). To add it, tick "Add .gif to File Name" in the menu bar menu. Microsoft Teams always gets the ".gif", because it only accepts pasted images with it (Teams doesn't show the name). Slack still shows it as an animated GIF.

## Notes

- To change the shortcut: menu bar icon → Change Shortcut…, then press the new combo (it must include ⌘, ⌃ or ⌥). It's saved across restarts. Esc cancels, and "Reset" restores ⌃⌥G.
- To change the rating (default `g`) or language, edit `Config` at the top of `GifPaste.swift` and rebuild.
- After each rebuild, macOS treats the app as new: remove GifPaste from Accessibility and add it again.
- The key is stored in your login Keychain (Keychain Access → search "GifPaste"). To change it: menu bar icon → Set GIPHY API Key…. The env var `GIPHY_API_KEY` overrides it.
- After a rebuild, macOS may ask once whether GifPaste may use the Keychain item. Click "Always Allow".
- A GIPHY development key is rate-limited (roughly 100 requests per hour).
- GIPHY's terms require "Powered by GIPHY" attribution, which is shown in the panel footer.
- App icon: source is `icon/icon.svg`; `icon/AppIcon.icns` is generated from it (rendered at 1024 px).
- Menu bar icon: source is `icon/menubar.svg`; `icon/MenuBarIcon.png` and `@2x.png` are generated from it (template image, adapts to light/dark mode).

## License

MIT, see [LICENSE](LICENSE). Inspired by the Raycast "GIF Search" extension (MIT, © 2021 Raycast), reimplemented in Swift. GIFs and the GIPHY API are subject to GIPHY's own terms (see developers.giphy.com).
