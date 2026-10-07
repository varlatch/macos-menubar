# Varlatch for macOS

Your [Varlatch](https://varlatch.com) sessions in the macOS menu bar.

This is early work: the menu bar app does not show sessions yet.

## Building

Needs macOS 13 or newer and Apple's Command Line Tools
(`xcode-select --install`); Xcode is not required.

```bash
scripts/bundle.sh          # builds build/Varlatch.app, signed ad hoc
open build/Varlatch.app
```

`scripts/bundle.sh --version 1.2.3` sets the app's version (default: the
latest `v*` tag). Options after `--` go to `swift build`.

## Development

- `Sources/VarlatchKit`: the logic, testable without a window server.
- `Sources/Varlatch`: the SwiftUI app.
- `scripts/test.sh` runs the tests (Swift Testing), with Xcode or the
  Command Line Tools.
- `swift scripts/make-icons.swift` makes the icons in `Resources/` from the
  marks in `assets/`.

To check the running app without clicking through it, turn on its debug
hooks and start it again:

```bash
defaults write com.varlatch.menubar debugHooks -bool true
```

It then writes its state to
`~/Library/Application Support/com.varlatch.menubar/debug-state.json` and
answers `notifyutil -p com.varlatch.menubar.debug.<name>`, where `<name>` is
`dump-state`, `open-panel`, `notify`, `login-on`, `login-off`,
`badge-none`, `badge-warning`, `badge-error`, or `settings`.

## License

Copyright © 2026 Robotsson. Licensed under the Apache License 2.0; see
[`LICENSE`](LICENSE).
