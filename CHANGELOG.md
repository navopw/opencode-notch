# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and releases use
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

### Added

- Permission prompts now drop a card with Allow / Always / Deny buttons, wired
  to the same reply endpoint the TUI uses. Cards for permissions answered in
  the TUI retract on their own, and an unanswered card times out after two
  minutes without inventing a response. Subagent permissions are included, with
  the session title on the card's meta line.
- Multiple notifications now stack inside one island, separated by hairlines,
  with permission cards pinned above idle ones. The stack is capped at four
  cards; overflow drops the oldest idle card, never a pending permission.
- Notifications from every running OpenCode instance share one island: the
  plugin talks to a single helper daemon over a Unix socket
  (`$TMPDIR/opencode-notch-<version>.sock`), spawned on demand and exiting
  about ten seconds after the last instance disconnects.
- Hovering the island holds its cards open; the dwell countdown resumes with a
  short grace once the pointer leaves. A small × appears on hover to dismiss a
  card by hand.
- The helper gained `--serve` (newline-delimited JSON on stdio) and
  `--serve --socket PATH` (multi-client daemon) modes; the one-shot
  positional-argv mode still works and remains the fallback.

### Changed

- Clicking a card no longer dismisses it — buttons and the hover × are the
  interactive surfaces, and clicks outside the island's exact silhouette pass
  through to the app underneath.
- Idle cards appear immediately from session data; branch, PR, and diff stats
  pour into the visible card a beat later instead of delaying it behind four
  subprocesses and a network call.
- The global 4.5 s debounce is gone; a repeat idle for the same session updates
  its existing card in place instead of being dropped.
- A resident helper now recomputes its geometry when displays change, so cards
  follow dock/undock and resolution switches, including the notched/notchless
  silhouette flip.

## 0.5.0 - 2026-07-29

### Fixed

- The card is now hung off the screen's top safe area instead of the raw frame,
  so on notched Macs its first 32pt no longer sits behind the camera housing and
  the menu bar row. Without a notch it floats just below the menu bar.

### Changed

- The card now animates like the iOS Dynamic Island. It grows out of the notch's
  own width on a spring that overshoots and settles, its corner radii open up as
  it expands, and the contents fade and scale in just behind the shape instead of
  riding along with it. Retracting collapses back into the notch without bounce.
- On a notched display the card's top corners now curve inward to meet the notch
  above them, so the two black shapes read as one.

## 0.4.0 - 2026-07-29

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
