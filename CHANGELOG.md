# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and releases use
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

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
