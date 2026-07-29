# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and releases use
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

### Added

- The package is now available under the MIT license.
- Clicking an open notch card now dismisses it with the retract animation.

### Fixed

- The native helper now reports the package version in its bundle metadata.

### Changed

- CI and releases now use the package lifecycle build without compiling the
  plugin and native helper twice.

## 0.3.0 - 2026-07-29

### Added

- The card now shows the current branch and, when the GitHub CLI finds one,
  the linked pull request number. Branch, PR, and diff stats are only gathered
  inside a git work tree.

### Fixed

- Changed-file, addition, and deletion counts now read from `git diff` instead
  of the session summary, which is reset to zeros and computed asynchronously
  after idle in opencode 1.18.9 and is therefore unavailable at notification
  time.

### Changed

- Notifications no longer play a sound.

## 0.2.0 - 2026-07-29

### Added

- Notch notifications now show changed-file, addition, and deletion counts.

### Changed

- The static checkmark tile now displays the changed-file count, or a neutral
  response icon when no files changed.

## 0.1.1 - 2026-07-29

### Changed

- Notifications now show the project directory name instead of `opencode`.

### Fixed

- The notch card now launches as a background UI element and no longer briefly
  steals keyboard focus from the current application.

## 0.1.0 - 2026-07-29

### Added

- Initial release. A Dynamic Island-style card drops down from the MacBook
  notch when OpenCode finishes a response, showing the session title next to a
  checkmark tile, then retracts after a few seconds. The card is drawn by a
  small compiled Swift helper and plays the Glass sound.
- Notifications fire only when the main session goes idle: subagent sessions
  are skipped and a short debounce prevents back-to-back popups.
- Falls back to a standard Notification Center banner when the helper binary
  has not been built.
