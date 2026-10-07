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
- Expiry notifications have **Renew Now** or **Log In**.
- After a full logout, **Log In** targets the last server used.
- Settings: check interval, expiry notifications, showing the icon while
  logged out, and localhost servers.
