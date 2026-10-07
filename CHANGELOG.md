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
- Settings: check interval, expiry notifications, showing the icon while
  logged out, and localhost servers.
