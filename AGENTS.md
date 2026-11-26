# AGENTS.md

## Commits

Use [Conventional Commits](https://www.conventionalcommits.org/). Releases are automated by release-please from these messages.

- `feat: …` new feature → minor release
- `fix: …` bug fix → patch release
- `feat!: …` or a `BREAKING CHANGE:` footer → major release
- `docs:`, `chore:`, `refactor:`, `ci:`, `build:` → no release

Never edit `CHANGELOG.md`, `version.txt` or `.release-please-manifest.json` by hand.

## Build

`scripts/build.sh dev` builds "GifPaste Dev" (separate bundle ID, settings and API key, shortcut ⌃⌥⇧G) and restarts it. Use it for testing; it runs next to the Homebrew version.
