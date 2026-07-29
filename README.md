# opencode-notch

[![npm](https://img.shields.io/npm/v/@navopw/opencode-notch)](https://www.npmjs.com/package/@navopw/opencode-notch)
[![CI](https://github.com/navopw/opencode-notch/actions/workflows/ci.yml/badge.svg)](https://github.com/navopw/opencode-notch/actions/workflows/ci.yml)

Dynamic Island-style macOS notch notifications for [OpenCode](https://opencode.ai/).

The plugin drops a black island card out of the MacBook notch whenever OpenCode
finishes a response. The card shows the project and session title, summarizes
changed files, additions, and deletions, and retracts after a few seconds. It is
drawn by a small compiled Swift helper, not a web view, so it looks and animates
like a native part of the menu bar.

<img width="600" height="300" alt="CleanShot 2026-07-29 at 14 56 03" src="https://github.com/user-attachments/assets/c9158637-48f2-4eb8-8aad-648ec421ff87" />

## Features

- Native island card that slides out of the notch with a slight spring bounce,
  rendered by a tiny Swift helper shipped prebuilt in the package
- Shows the project and auto-generated session title, so you know which task
  finished
- Shows the current branch and, when the GitHub CLI finds one, the linked pull
  request number
- Summarizes changed files, additions, and deletions when a response edits code;
  branch, PR, and diff stats only appear inside a git work tree
- Fires only when the main session goes idle: subagent sessions are skipped and
  a short debounce prevents back-to-back popups
- Width hugs the content like the real Dynamic Island; the card never steals
  focus and dismisses itself
- Falls back to a standard Notification Center banner when the helper binary is
  missing
- Zero configuration

## Install

Requires macOS on Apple Silicon, [Bun](https://bun.sh/) `1.3.0` or newer, and
OpenCode `1.18.9` or newer.

Add the package to the `plugin` array in your OpenCode config, either
`~/.config/opencode/opencode.json` for every project or `opencode.json` in a
single repository:

```jsonc
{
	"$schema": "https://opencode.ai/config.json",
	"plugin": ["@navopw/opencode-notch"]
}
```

OpenCode installs the package with Bun on startup and caches it under
`~/.cache/opencode/node_modules/`. Quit and restart OpenCode after editing the
config. The notification helper ships prebuilt in the package, so no Xcode or
compile step is needed at install time.

Verify the installation by letting OpenCode finish any response: a black island
card should drop from the notch and retract after a few seconds.

Pin a version if you would rather approve updates yourself:

```jsonc
{
	"plugin": ["@navopw/opencode-notch@0.1.0"]
}
```

### Update

Quit every running OpenCode process before updating.

An unpinned npm install picks up the newest release on the next OpenCode
startup. Clear the cache to force a re-resolve:

```sh
rm -rf ~/.cache/opencode/node_modules
```

Restart OpenCode after updating.

### Remove

Remove the plugin entry from your OpenCode config and restart OpenCode.

## Platform support

| Platform | Status |
| --- | --- |
| macOS (Apple Silicon) | Fully supported, CI builds the helper here |
| macOS (Intel) | Not supported, excluded via the `cpu` field |
| Linux, Windows | Not supported, excluded via the `os` field |

A notched MacBook gives the intended look: the card merges with the notch as it
drops down. On other Apple Silicon Macs or external displays it still appears,
sliding in from the top center of the screen.

## Development

```sh
bun install --frozen-lockfile
bun run check
bun run build
bun run build:swift
bun audit
```

`bun run build` compiles the published `dist/`. `bun run build:swift` compiles
the notification helper and assembles `swift/notch.app`, a background
UI-element bundle that never takes keyboard focus. It requires the Xcode
toolchain (`swiftc`). Run `open -g -n ./swift/notch.app --args "opencode"
"Hello" 3 42 10 "main" "12"` to preview the card without activating it (branch
and PR args are optional).

To release: move the `Unreleased` changelog entries into a new section, bump
`version` in `package.json`, commit as `chore(release): x.y.z`, tag `vx.y.z`,
and push with tags. The Release workflow verifies the tag, builds, and
publishes to npm.

See [CHANGELOG.md](CHANGELOG.md) for release history.
