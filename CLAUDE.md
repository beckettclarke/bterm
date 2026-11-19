# bterm

## Releases

Pushing a `vX.Y.Z` tag runs `.github/workflows/release.yml`, which builds, publishes the GitHub release and updates the Homebrew cask. The release notes start with that version's section of `CHANGELOG.md`, and the in-app updater shows them, so add the section before tagging.

Write changelog entries as short sentences a user would understand, about what changed for them rather than how. For example:

- Redesigned app icon
- New space selector dropdown in horizontal tabs mode
- Added onboarding screen
- Revamped adblocker
