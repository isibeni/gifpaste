# AGENTS.md

## Commits

Use [Conventional Commits](https://www.conventionalcommits.org/). Releases are automated by release-please from these messages.

- `feat: …` new feature → minor release
- `fix: …` bug fix → patch release
- `feat!: …` or a `BREAKING CHANGE:` footer → major release
- `docs:`, `chore:`, `refactor:`, `ci:`, `build:` → no release

Never edit `CHANGELOG.md`, `version.txt` or `.release-please-manifest.json` by hand.

## Build

`scripts/build.sh install` builds, installs to /Applications and restarts the app.
