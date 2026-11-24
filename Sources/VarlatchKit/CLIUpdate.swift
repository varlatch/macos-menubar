import Foundation

/// How the CLI the app runs goes to a newer release.
public enum CLIUpdateWay: Equatable, Sendable {
    /// `brew upgrade varlatch`.
    case homebrew
    /// `varlatch self-update <version>`: the native CLI (0.50 and later).
    case selfUpdate
    /// A Terminal script for the pre-0.50 single-file CLI: uses the release's
    /// verified `install.sh` when the target release ships a native macOS
    /// binary, else the CLI's own `self-update`.
    case installer
    /// Release notes only: updated the way it was installed.
    case manual
}

/// Pure rules and shell commands for updating the CLI in Terminal.
public enum CLIUpdate {
    /// Decides how to update the CLI at `path` of `kind` and `version`.
    public static func way(kind: CLIInstall?, path: String?, version: Version?, isNative: Bool? = nil) -> CLIUpdateWay {
        if kind == .homebrew { return .homebrew }
        guard kind == .release, let path, let version else { return .manual }
        // Older CLIs have no self-update, and -dev builds refuse it.
        if version < Version.selfUpdate || version.description.hasSuffix("-dev") { return .manual }
        let native = isNative ?? CLIInstall.isNative(path)
        if native { return .selfUpdate }
        // `install.sh --dir` always writes the file named `varlatch`.
        guard URL(fileURLWithPath: path).lastPathComponent == "varlatch" else { return .manual }
        return .installer
    }

    /// 'text' for a shell, with single quotes inside escaped.
    public static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Command for updating a native CLI with its own `self-update`.
    /// Checks writability of the symlink-resolved file's directory because
    /// the native `self-update` writes beside the real file.
    public static func selfUpdateCommand(path: String, version: Version, writable: Bool? = nil) -> String {
        let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let dir = (real as NSString).deletingLastPathComponent
        let canWrite = writable ?? FileManager.default.isWritableFile(atPath: dir)
        let quoted = shellQuoted(path)
        let ver = shellQuoted(version.description)
        return canWrite ? "\(quoted) self-update \(ver)" : "sudo \(quoted) self-update \(ver)"
    }

    /// Bash script for updating a pre-0.50 single-file CLI at `path` to
    /// `version`. Uses sudo based on the invoked path's directory (where both
    /// `install.sh --dir` and the TypeScript `self-update` write). When the
    /// target release lists a native macOS binary in `SHA256SUMS`, reads
    /// `install.sh` into memory, hashes those exact bytes against
    /// `SHA256SUMS`, checks for any Homebrew CLI on PATH before asking, backs
    /// up the old CLI beside the target, pipes the verified bytes directly to
    /// `[sudo] sh -s -- --version <v> --dir <dir>`, and checks that the target
    /// runs afterwards (restoring the backup by one atomic `mv -f` if needed,
    /// keeping the backup and printing its path if recovery fails).
    public static func installerScript(
        path: String,
        version: Version,
        repository: String = ReleaseChecker.repository,
        needsSudo: Bool? = nil
    ) -> String {
        let dir = (path as NSString).deletingLastPathComponent
        let useSudo = needsSudo ?? !FileManager.default.isWritableFile(atPath: dir)
        return """
            (
            set -euo pipefail
            cli=\(shellQuoted(path))
            dir=\(shellQuoted(dir))
            version=\(shellQuoted(version.description))
            repo=\(shellQuoted(repository))
            use_sudo=\(useSudo ? "yes" : "no")
            base="https://github.com/$repo/releases/download/v$version"

            case "$(uname -m)" in
              arm64|aarch64) arch=arm64 ;;
              x86_64|amd64) arch=amd64 ;;
              *) echo "varlatch: unsupported architecture $(uname -m)" >&2; exit 1 ;;
            esac

            tmp=$(mktemp -d)
            trap 'rm -rf "$tmp"' EXIT

            curl -q -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2 --retry 2 \\
              -o "$tmp/SHA256SUMS" "$base/SHA256SUMS" \\
              || { echo "varlatch: could not download SHA256SUMS for v$version" >&2; exit 1; }

            listed_hash() {
              awk -v name="$1" '
                length($1) == 64 && $1 ~ /^[0-9a-f]+$/ && ($2 == name || $2 == "*" name) { hash = $1; n++ }
                END { if (n == 1) print hash; else exit 1 }
              ' "$tmp/SHA256SUMS"
            }

            sha256_stdin() {
              if command -v shasum >/dev/null 2>&1; then
                shasum -a 256 | awk '{print $1}'
              else
                sha256sum | awk '{print $1}'
              fi
            }

            is_brew_path() {
              local lower
              lower=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
              case "$lower" in
                /opt/homebrew|/opt/homebrew/*|/usr/local/homebrew|/usr/local/homebrew/*|/usr/local/cellar|/usr/local/cellar/*|/home/linuxbrew|/home/linuxbrew/*)
                  return 0 ;;
              esac
              return 1
            }

            is_brew_entry() {
              local entry=$1 resolved=""
              [ -e "$entry" ] || [ -L "$entry" ] || return 1
              is_brew_path "$entry" && return 0
              if command -v python3 >/dev/null 2>&1; then
                resolved=$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$entry" 2>/dev/null || true)
              elif command -v readlink >/dev/null 2>&1; then
                resolved=$(readlink "$entry" 2>/dev/null || true)
              fi
              [ -n "$resolved" ] && is_brew_path "$resolved" && return 0
              grep -aq 'installed with Homebrew' "$entry" 2>/dev/null && return 0
              [ -n "$resolved" ] && grep -aq 'installed with Homebrew' "$resolved" 2>/dev/null && return 0
              return 1
            }

            find_brew_on_path() {
              local saved_ifs=$IFS entry=""
              IFS=:
              for entry in $PATH; do
                if [ -n "$entry" ] && is_brew_entry "$entry/varlatch"; then
                  IFS=$saved_ifs
                  printf '%s' "$entry/varlatch"
                  return 0
                fi
              done
              IFS=$saved_ifs
              return 1
            }

            native_asset="varlatch-$version-darwin-$arch"
            if listed_hash "$native_asset" >/dev/null 2>&1; then
              if brew_cli=$(find_brew_on_path); then
                echo "varlatch: found a Homebrew CLI at $brew_cli on your PATH; install.sh refuses to install alongside Homebrew. Update it with: brew upgrade varlatch" >&2
                exit 1
              fi

              want_install=$(listed_hash "install.sh") || {
                echo "varlatch: SHA256SUMS does not list install.sh once; nothing was installed" >&2
                exit 1
              }
              curl -q -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2 --retry 2 \\
                -o "$tmp/install.sh" "$base/install.sh" \\
                || { echo "varlatch: could not download install.sh for v$version" >&2; exit 1; }

              # Read the installer into memory (preserving trailing newlines),
              # hash those exact bytes, and pipe those same bytes to sh.
              script=$(cat "$tmp/install.sh"; printf x)
              script=${script%x}
              got_install=$(printf '%s' "$script" | sha256_stdin)
              if [ "$got_install" != "$want_install" ]; then
                echo "varlatch: install.sh does not match SHA256SUMS; nothing was installed" >&2
                exit 1
              fi

              printf '\\n  varlatch %s\\n  install:  %s\\n  checksum: ok (SHA256SUMS)\\n  changes:  https://github.com/%s/releases/tag/v%s\\n\\n' \\
                "$version" "$cli" "$repo" "$version"
              printf 'Install? [y/N] '
              answer=''
              read -r answer || answer=''
              case "$answer" in
                [yY]*) ;;
                *) echo 'Nothing installed.'; exit 130 ;;
              esac

              old=""
              if [ -e "$cli" ] || [ -L "$cli" ]; then
                old="$dir/.varlatch-old.$$"
                if [ "$use_sudo" = yes ]; then
                  sudo cp -Pp "$cli" "$old" || { echo "varlatch: could not back up $cli; nothing was installed" >&2; exit 1; }
                else
                  cp -Pp "$cli" "$old" || { echo "varlatch: could not back up $cli; nothing was installed" >&2; exit 1; }
                fi
              fi

              restore_old() {
                local reason=$1 code=$2
                if [ -n "$old" ]; then
                  if [ "$use_sudo" = yes ]; then
                    if sudo mv -f "$old" "$cli"; then
                      echo "varlatch: $reason; the old CLI is back." >&2
                    else
                      echo "varlatch: $reason, and the old CLI could not be restored automatically; backup kept at $old." >&2
                    fi
                  else
                    if mv -f "$old" "$cli"; then
                      echo "varlatch: $reason; the old CLI is back." >&2
                    else
                      echo "varlatch: $reason, and the old CLI could not be restored automatically; backup kept at $old." >&2
                    fi
                  fi
                else
                  echo "varlatch: $reason." >&2
                fi
                exit "$code"
              }

              rc=0
              if [ "$use_sudo" = yes ]; then
                printf '%s' "$script" | sudo sh -s -- --version "$version" --dir "$dir" || rc=$?
              else
                printf '%s' "$script" | sh -s -- --version "$version" --dir "$dir" || rc=$?
              fi

              reported=$("$cli" --version 2>/dev/null || true)
              if [ "$rc" -ne 0 ]; then
                if [ -z "$reported" ]; then
                  restore_old "update failed (exit $rc) and $cli does not run" "$rc"
                fi
                if [ -n "$old" ]; then
                  if [ "$use_sudo" = yes ]; then sudo rm -f "$old"; else rm -f "$old"; fi
                fi
                exit "$rc"
              fi

              case "$reported" in
                "varlatch $version"|"varlatch $version "*) ;;
                *) restore_old "the new CLI does not run at $cli" 1 ;;
              esac
              if [ -n "$old" ]; then
                if [ "$use_sudo" = yes ]; then sudo rm -f "$old"; else rm -f "$old"; fi
              fi
            elif listed_hash "varlatch-cli-$version.cjs" >/dev/null 2>&1; then
              if [ "$use_sudo" = yes ]; then
                node_bin=$(command -v node) || { echo "varlatch: node was not found" >&2; exit 1; }
                sudo "$node_bin" "$cli" self-update "$version"
              else
                "$cli" self-update "$version"
              fi
            else
              echo "varlatch: release $version has no CLI for this Mac in SHA256SUMS; nothing was installed" >&2
              exit 1
            fi
            )
            """
    }
}
