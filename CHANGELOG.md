# Changelog

## Unreleased

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
- Settings: check interval, expiry notifications, showing the icon while
  logged out, and localhost servers.
