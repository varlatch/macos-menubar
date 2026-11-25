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

    /// Whether `path` is owned by root (uid 0) and not group- or other-writable.
    public static func isRootSafe(_ path: String, fileManager: FileManager = .default) -> Bool {
        guard let attrs = try? fileManager.attributesOfItem(atPath: path),
              let uid = attrs[.ownerAccountID] as? NSNumber,
              let perms = attrs[.posixPermissions] as? NSNumber else { return false }
        return uid.intValue == 0 && (perms.uint16Value & 0o022) == 0
    }

    /// Command for updating a native CLI with its own `self-update`.
    /// Checks writability of the symlink-resolved file's directory because
    /// the native `self-update` writes beside the real file. Only elevates
    /// the resolved executable when both the resolved file and its directory
    /// are root-owned and not group- or other-writable; otherwise refuses and
    /// prints the command to run by hand.
    public static func selfUpdateCommand(
        path: String,
        version: Version,
        writable: Bool? = nil,
        rootSafe: ((String) -> Bool)? = nil
    ) -> String {
        let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let dir = (real as NSString).deletingLastPathComponent
        let canWrite = writable ?? FileManager.default.isWritableFile(atPath: dir)
        let quotedReal = shellQuoted(real)
        let ver = shellQuoted(version.description)
        if canWrite {
            return "\(quotedReal) self-update \(ver)"
        }
        let checkSafe = rootSafe ?? { isRootSafe($0) }
        if checkSafe(real) && checkSafe(dir) {
            return "sudo \(quotedReal) self-update \(ver)"
        }
        let manual = "\(quotedReal) self-update \(ver)"
        let msg = "varlatch: refusing to run sudo on \(real) (must be root-owned and not group- or other-writable). Run by hand: \(manual)"
        return "printf '%s\\n' \(shellQuoted(msg)) >&2; exit 1"
    }

    /// Bash script for updating a pre-0.50 single-file CLI at `path` to
    /// `version`. Uses sudo based on the invoked path's directory (and only
    /// when root-owned and not group- or other-writable; else refuses with the
    /// manual command). When `cosign` is installed, verifies `SHA256SUMS`'s
    /// signature (pinned identity and OIDC issuer) before the manifest
    /// authorizes `install.sh`. Reads `install.sh` into memory, hashes those
    /// exact bytes, pipes them to `[sudo] sh -s -- --version <v> --dir <dir>`,
    /// checks both exit status 0 and expected version before removing the
    /// backup, and traps INT/TERM/HUP after backup through atomic `mv -f`
    /// recovery.
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
            old=""
            install_started=no
            verified=no

            restore_old_once() {
              local reason=$1
              if [ -n "$old" ] && { [ -e "$old" ] || [ -L "$old" ]; }; then
                if [ "$use_sudo" = yes ]; then
                  if sudo mv -f "$old" "$cli"; then
                    old=""
                    echo "varlatch: $reason; the old CLI is back." >&2
                  else
                    echo "varlatch: $reason, and the old CLI could not be restored automatically; backup kept at $old." >&2
                  fi
                else
                  if mv -f "$old" "$cli"; then
                    old=""
                    echo "varlatch: $reason; the old CLI is back." >&2
                  else
                    echo "varlatch: $reason, and the old CLI could not be restored automatically; backup kept at $old." >&2
                  fi
                fi
              else
                echo "varlatch: $reason." >&2
              fi
            }

            cleanup() {
              rm -rf "$tmp"
              if [ "$verified" != yes ]; then
                if [ "$install_started" = yes ]; then
                  restore_old_once "update interrupted or did not complete"
                elif [ -n "$old" ]; then
                  if [ "$use_sudo" = yes ]; then sudo rm -f "$old" 2>/dev/null || true; else rm -f "$old" 2>/dev/null || true; fi
                fi
              fi
            }
            trap cleanup EXIT
            trap 'exit 129' HUP
            trap 'exit 130' INT
            trap 'exit 143' TERM

            is_root_safe() {
              local p=$1 info uid mode
              [ -e "$p" ] || return 1
              if [ "$(uname -s)" = Darwin ]; then
                info=$(stat -f '%u %Lp' "$p" 2>/dev/null) || return 1
              else
                info=$(stat -c '%u %a' "$p" 2>/dev/null) || return 1
              fi
              uid=${info%% *}; mode=${info#* }
              [ "$uid" = "0" ] && [ $((8#$mode & 8#022)) -eq 0 ]
            }

            # Full symlink resolution in pure sh (up to 40 hops), no python.
            resolve_path() {
              local p=$1 hops=0 pdir link
              while [ -L "$p" ] && [ "$hops" -lt 40 ]; do
                pdir=$(dirname "$p")
                link=$(readlink "$p") || break
                case "$link" in
                  /*) p=$link ;;
                  *) p="$pdir/$link" ;;
                esac
                hops=$((hops + 1))
              done
              pdir=$(cd "$(dirname "$p")" 2>/dev/null && pwd -P) || { printf '%s' "$p"; return 0; }
              printf '%s/%s' "${pdir%/}" "$(basename "$p")"
            }

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

            has_brew_marker() {
              [ -f "$1" ] || return 1
              [ "$(head -c 2 "$1" 2>/dev/null || true)" = "#!" ] || return 1
              head -c 512 "$1" 2>/dev/null | grep -aq 'installed with Homebrew'
            }

            is_brew_entry() {
              local entry=$1 resolved=""
              [ -e "$entry" ] || [ -L "$entry" ] || return 1
              is_brew_path "$entry" && return 0
              resolved=$(resolve_path "$entry")
              [ -n "$resolved" ] && is_brew_path "$resolved" && return 0
              has_brew_marker "$entry" && return 0
              [ -n "$resolved" ] && has_brew_marker "$resolved" && return 0
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

              if [ "$use_sudo" = yes ]; then
                if ! is_root_safe "$dir" || { [ -e "$cli" ] && [ ! -L "$cli" ] && ! is_root_safe "$cli"; }; then
                  echo "varlatch: refusing to run sudo on $dir (must be root-owned and not group- or other-writable). Update by hand using install.sh --version $version --dir $dir" >&2
                  exit 1
                fi
              fi

              # When cosign is installed, verify SHA256SUMS's Sigstore signature
              # before the manifest authorizes install.sh; any failure stops.
              if command -v cosign >/dev/null 2>&1; then
                curl -q -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2 --retry 2 \\
                  -o "$tmp/SHA256SUMS.sigstore.json" "$base/SHA256SUMS.sigstore.json" \\
                  || { echo "varlatch: cosign is installed, but SHA256SUMS.sigstore.json could not be downloaded; nothing was installed" >&2; exit 1; }
                cosign verify-blob "$tmp/SHA256SUMS" \\
                  --bundle "$tmp/SHA256SUMS.sigstore.json" \\
                  --certificate-identity "https://github.com/$repo/.github/workflows/release.yml@refs/tags/v$version" \\
                  --certificate-oidc-issuer "https://token.actions.githubusercontent.com" >/dev/null 2>&1 \\
                  || { echo "varlatch: cosign signature verification of SHA256SUMS failed; nothing was installed" >&2; exit 1; }
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

              if [ -e "$cli" ] || [ -L "$cli" ]; then
                old="$dir/.varlatch-old.$$"
                if [ "$use_sudo" = yes ]; then
                  sudo cp -Pp "$cli" "$old" || { old=""; echo "varlatch: could not back up $cli; nothing was installed" >&2; exit 1; }
                else
                  cp -Pp "$cli" "$old" || { old=""; echo "varlatch: could not back up $cli; nothing was installed" >&2; exit 1; }
                fi
              fi

              install_started=yes
              rc=0
              if [ "$use_sudo" = yes ]; then
                printf '%s' "$script" | sudo sh -s -- --version "$version" --dir "$dir" || rc=$?
              else
                printf '%s' "$script" | sh -s -- --version "$version" --dir "$dir" || rc=$?
              fi

              ver_rc=0
              reported=$("$cli" --version 2>/dev/null) || ver_rc=$?
              if [ "$rc" -ne 0 ]; then
                if [ "$ver_rc" -ne 0 ] || [ -z "$reported" ]; then
                  restore_old_once "update failed (exit $rc) and $cli does not run"
                  install_started=no
                  exit "$rc"
                fi
                # Target still answers cleanly: leave it and clean backup.
                install_started=no
                if [ -n "$old" ]; then
                  if [ "$use_sudo" = yes ]; then sudo rm -f "$old"; else rm -f "$old"; fi
                  old=""
                fi
                exit "$rc"
              fi

              if [ "$ver_rc" -ne 0 ]; then
                restore_old_once "the new CLI exited $ver_rc at $cli"
                install_started=no
                exit 1
              fi
              case "$reported" in
                "varlatch $version"|"varlatch $version "*) ;;
                *)
                  restore_old_once "the new CLI reported '$reported' instead of $version at $cli"
                  install_started=no
                  exit 1 ;;
              esac

              verified=yes
              if [ -n "$old" ]; then
                if [ "$use_sudo" = yes ]; then sudo rm -f "$old"; else rm -f "$old"; fi
                old=""
              fi
            elif listed_hash "varlatch-cli-$version.cjs" >/dev/null 2>&1; then
              if [ "$use_sudo" = yes ]; then
                node_bin=$(command -v node) || { echo "varlatch: node was not found" >&2; exit 1; }
                node_real=$(resolve_path "$node_bin")
                cli_real=$(resolve_path "$cli")
                if is_root_safe "$cli_real" && is_root_safe "$(dirname "$cli_real")" && is_root_safe "$dir" \\
                    && is_root_safe "$node_real" && is_root_safe "$(dirname "$node_real")"; then
                  sudo "$node_real" "$cli_real" self-update "$version"
                else
                  echo "varlatch: refusing to run sudo on $cli_real (target, node, and their directories must be root-owned and not group- or other-writable). Update by hand: '$node_real' '$cli_real' self-update '$version'" >&2
                  exit 1
                fi
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
