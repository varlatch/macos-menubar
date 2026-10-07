# Changelog

## 0.2.0 (2026-10-07)

- **Restart after an upgrade:** after `brew upgrade varlatch-menubar` (or
  a reinstall or rebuild in place), the panel shows that a newer copy is
  installed, with **Restart**, and one notification offers **Restart
  Now**. Restart waits while a sign-in is under way.

## 0.1.0 (2026-10-07)

First release, installed with
`brew install varlatch/tap/varlatch varlatch/tap/varlatch-menubar`.

- **Sessions in the menu bar**, read offline from `varlatch status --json`
  every 30 seconds: the Varlatch mark with an amber badge while a credential
  is expiring and a red one when signed out, expired, or the CLI cannot be
  used. The panel lists each server with a live countdown; a tooltip shows
  the same.
- One notification for each move into *expiring* or *expired*.
- Finds the CLI in `/opt/homebrew/bin`, `/usr/local/bin`, or `~/.local/bin`
  when opened from Finder, and runs it with a `PATH` that finds `node`.
- Opens at login; a Homebrew install does so through a LaunchAgent that
  follows `brew upgrade`.
- **Actions:** sign in, renew, and log out per server; **Verify**
  (`varlatch status --probe`) with the results on the rows; **Open
  Dashboard**. A sign-in runs without a terminal window: the panel shows it
  waiting, with **Open Link** and **Cancel**, and the result arrives as a
  notification. Quitting the app cancels it.
- **Sign in from another device** (CLI 0.14.0 or newer), for when the
  browser here has no passkey: the panel shows an address, a code, and a QR
  code of the address. Start it with **Other Device** on a waiting sign-in,
  **Sign In from Another Device** in a server's menu, or the buttons on a
  failed sign-in's and the expiry notifications.
- **Session length:** 1 to 24 hours, or the server's default of 12, for
  every sign-in the app starts.
- Expiry notifications have **Renew Now** or **Log In**.
- After a full logout, **Log In** targets the last server used.
- **First run:** without the CLI, the panel offers to install it with
  Homebrew in Terminal; with no server known, it asks for the server's
  address. **Add Server** signs in to one more.
- **CLI updates** (opt-in): an anonymous check for new releases, at most
  once an hour, with **Release Notes** and **Update in Terminal**
  (`brew upgrade varlatch`, or `varlatch self-update` for the release
  build), and one notification per release.
- Settings: session length, check interval, expiry notifications, showing
  the icon while logged out, localhost servers, the CLI path, and release
  checks.
