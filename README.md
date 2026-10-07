<p align="center">
  <img src="assets/app-icon-256.png" width="96" alt="">
</p>

<h1 align="center">Varlatch for macOS</h1>

<p align="center">
  Your <a href="https://github.com/varlatch/varlatch">Varlatch</a> sessions in the macOS menu bar:
  which servers you are signed in to, and when each credential expires.
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-Apache--2.0-blue" alt="License: Apache-2.0"></a>
</p>

Everything it shows comes from `varlatch status --json`, which reads local
files only. Needs macOS 13 or newer and the `varlatch` CLI.

## What it shows

The Varlatch mark in the menu bar, in the system's own monochrome, with a
small badge when something needs attention:

- **no badge:** every session is live
- **amber:** less than 20% of a credential's lifetime remains
- **red:** signed out, a credential has expired, or the CLI cannot be used
  (the mark is dimmed then)

A click opens a panel with one row per server and a live countdown
("Logged in, 3h 12m left"), or what stands in the way: no CLI, a CLI too
old for `varlatch status`, or its error. Hovering the icon shows the same
in a tooltip.

Moving into *expiring* or *expired* triggers one notification each. The
app asks for permission to notify when it first starts; without it, it
works the same, just silently.

Servers on `localhost` or `127.*` are left out unless **Show localhost
servers** is on.

## Privacy

The app runs `varlatch status --json` on a timer. That command reads
`~/.config/varlatch/credentials.json` and repository-local state; it makes
no network requests and never uses a stored credential. The app never reads
the credentials file itself.

## Settings

**Varlatch > Settings** (the gear in the panel), stored in the app's user
defaults (`defaults read com.varlatch.menubar`):

- **Open at login** (on): starts the app when you log in.
- **Check sessions every** (30 seconds, at least 15).
- **Notify before a session expires** (on).
- **Show in the menu bar when logged out** (on). With it off, the icon
  disappears while no credentials are stored; open the app again (from
  Finder, Spotlight, or Launchpad) to get to Settings.
- **Show localhost servers** (off).

## Finding the CLI

Apps opened from Finder do not get your shell's `PATH`, so the app looks
for `varlatch` in `/opt/homebrew/bin`, `/usr/local/bin`, and
`~/.local/bin`, and runs it with those directories in front of the `PATH`,
so the release CLI finds `node` too.

## Opening at login

Installed with Homebrew, the app runs from a versioned directory that
`brew upgrade` replaces, so it opens at login through a LaunchAgent
(`~/Library/LaunchAgents/com.varlatch.menubar.login.plist`) that opens
Homebrew's stable `opt` link. Installed anywhere else, it is a regular
login item. Either way, it shows as "Varlatch" in **System Settings >
General > Login Items & Extensions**, and **Open at login** turns it off.

## Building

Needs Apple's Command Line Tools (`xcode-select --install`); Xcode is not
required.

```bash
scripts/bundle.sh          # builds build/Varlatch.app, signed ad hoc
open build/Varlatch.app
```

`scripts/bundle.sh --version 1.2.3` sets the app's version (default: the
latest `v*` tag). Options after `--` go to `swift build`.

## Development

- `Sources/VarlatchKit`: the logic (finding and running the CLI, reading
  its status, the expiry rules), testable without a window server.
- `Sources/Varlatch`: the SwiftUI app.
- `scripts/test.sh` runs the tests (Swift Testing), with Xcode or the
  Command Line Tools.
- `Tests/fake-varlatch` stands in for the CLI, in the tests and for trying
  the app without a server: point **CLI path** at it
  (`defaults write com.varlatch.menubar cliPath "$PWD/Tests/fake-varlatch"`)
  and give it a directory with a `status.json` in `FAKE_VARLATCH_DIR`. See
  the script for the rest.
- `swift scripts/make-icons.swift` makes the icons in `Resources/` from the
  marks in `assets/`.

To check the running app without clicking through it, turn on its debug
hooks and open it again:

```bash
defaults write com.varlatch.menubar debugHooks -bool true
```

It then keeps its state in
`~/Library/Application Support/com.varlatch.menubar/debug-state.json` and
answers `notifyutil -p com.varlatch.menubar.debug.<name>`, where `<name>` is
`dump-state`, `open-panel`, `settings`, or `refresh`.

See [`CHANGELOG.md`](CHANGELOG.md) for what changed in each release.

## License

Copyright © 2026 Robotsson. Licensed under the Apache License 2.0; see
[`LICENSE`](LICENSE).
