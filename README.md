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

- Native island card that grows out of the notch on a spring that overshoots and
  settles, its corner radii opening up as it expands and its contents fading in
  behind the shape, rendered by a tiny Swift helper shipped prebuilt in the
  package
- Multiple notifications stack inside one island — even across several OpenCode
  instances, which all share a single background helper — with permission cards
  pinned above idle ones
- Allow / Always / Deny buttons for OpenCode permission prompts, answered
  through the same endpoint the TUI uses; unanswered cards time out without
  inventing a response
- Shows the project and auto-generated session title, so you know which task
  finished
- Shows the current branch on the card's first frame — it is read straight out
  of `.git/HEAD`, not shelled out for — and, when the GitHub CLI finds one, the
  linked pull request number a beat later
- Summarizes changed files, additions, and deletions when a response edits code;
  branch, PR, and diff stats only appear inside a git work tree
- Idle notifications fire only when the main session goes idle: subagent
  sessions are skipped, and repeat notifications for the same session update
  the existing card in place
- Hovering a card holds it open; a small × appears on hover to dismiss it, and
  clicks anywhere else pass straight through to the app underneath
- Width hugs the content like the real Dynamic Island; the island never steals
  focus
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
	"plugin": ["@navopw/opencode-notch@0.5.0"]
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

A notched MacBook gives the intended look: the card grows out of the notch and
overlaps it, so the two black shapes read as one. On other Apple Silicon Macs or
external displays it still appears, blooming from a pill-sized sliver at the
very top of the screen — a virtual notch over the empty center of the menu
bar — with the spring damped so it does not bounce.

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
UI-element bundle that never takes keyboard focus. The build synchronizes its
bundle version with `package.json`. It requires the Xcode toolchain (`swiftc`).
Run `open -g -n ./swift/notch.app --args "opencode" "Hello" 3 42 10 "main"
"12"` to preview a single card without activating it (branch and PR args are
optional).

At runtime the plugin talks to one shared helper daemon over a Unix socket at
`$TMPDIR/opencode-notch-<version>.sock`, spawning it on demand; the daemon
exits about ten seconds after the last OpenCode instance disconnects. To poke
at the newline-delimited JSON protocol by hand, run the binary in stdio mode:

```sh
./swift/notch.app/Contents/MacOS/notch --serve
{"cmd":"show","id":"x","kind":"idle","dwell":3,"title":"hello","subtitle":"world"}
```

The full protocol is documented in the header of `swift/notch.swift`.

To release: move the `Unreleased` changelog entries into a new section, bump
`version` in `package.json`, commit as `chore(release): x.y.z`, tag `vx.y.z`,
and push with tags. The Release workflow verifies the tag, builds, and
publishes to npm.

See [CHANGELOG.md](CHANGELOG.md) for release history.

## License

[MIT](LICENSE)
