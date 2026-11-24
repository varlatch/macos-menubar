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
    /// `self-update` writes beside the real file.
    public static func selfUpdateCommand(path: String, version: Version, writable: Bool? = nil) -> String {
        let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let dir = (real as NSString).deletingLastPathComponent
        let canWrite = writable ?? FileManager.default.isWritableFile(atPath: dir)
        let quoted = shellQuoted(path)
        let ver = shellQuoted(version.description)
        return canWrite ? "\(quoted) self-update \(ver)" : "sudo \(quoted) self-update \(ver)"
    }

    /// Bash script for updating a pre-0.50 single-file CLI at `path` to
    /// `version`. Inspects the release's `SHA256SUMS`: when it lists the
    /// native macOS binary for this Mac, downloads `install.sh`, checks its
    /// SHA-256 against `SHA256SUMS`, asks before replacing anything, keeps a
    /// backup of the old CLI until the new one runs in place, and runs
    /// `install.sh --version <v> --dir <dir>`. Otherwise hands off to the
    /// CLI's own `self-update`.
    public static func installerScript(
        path: String,
        version: Version,
        repository: String = ReleaseChecker.repository,
        needsSudo: Bool? = nil
    ) -> String {
        let dir = (path as NSString).deletingLastPathComponent
        let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let realDir = (real as NSString).deletingLastPathComponent
        let installSudo = needsSudo ?? !FileManager.default.isWritableFile(atPath: dir)
        let selfSudo = needsSudo ?? !FileManager.default.isWritableFile(atPath: realDir)
        return """
            (
            set -euo pipefail
            cli=\(shellQuoted(path))
            dir=\(shellQuoted(dir))
            version=\(shellQuoted(version.description))
            repo=\(shellQuoted(repository))
            install_sudo=\(installSudo ? "yes" : "no")
            self_sudo=\(selfSudo ? "yes" : "no")
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

            sha256_file() {
              if command -v shasum >/dev/null 2>&1; then
                shasum -a 256 "$1" | awk '{print $1}'
              else
                sha256sum "$1" | awk '{print $1}'
              fi
            }

            native_asset="varlatch-$version-darwin-$arch"
            if listed_hash "$native_asset" >/dev/null 2>&1; then
              want_install=$(listed_hash "install.sh") || {
                echo "varlatch: SHA256SUMS does not list install.sh once; nothing was installed" >&2
                exit 1
              }
              curl -q -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2 --retry 2 \\
                -o "$tmp/install.sh" "$base/install.sh" \\
                || { echo "varlatch: could not download install.sh for v$version" >&2; exit 1; }
              got_install=$(sha256_file "$tmp/install.sh")
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

              had_old=no
              if [ -e "$cli" ] || [ -L "$cli" ]; then
                cp -Pp "$cli" "$tmp/old-varlatch"
                had_old=yes
              fi

              rc=0
              if [ "$install_sudo" = yes ]; then
                sudo sh "$tmp/install.sh" --version "$version" --dir "$dir" || rc=$?
              else
                sh "$tmp/install.sh" --version "$version" --dir "$dir" || rc=$?
              fi

              if [ "$rc" -ne 0 ]; then
                if [ "$had_old" = yes ] && [ ! -e "$cli" ] && [ ! -L "$cli" ]; then
                  if [ "$install_sudo" = yes ]; then sudo cp -Pp "$tmp/old-varlatch" "$cli"; else cp -Pp "$tmp/old-varlatch" "$cli"; fi
                fi
                exit "$rc"
              fi

              reported=$("$cli" --version 2>/dev/null || true)
              case "$reported" in
                "varlatch $version"|"varlatch $version "*) ;;
                *)
                  echo "varlatch: the new CLI does not run at $cli; putting the old CLI back." >&2
                  if [ "$had_old" = yes ]; then
                    if [ "$install_sudo" = yes ]; then
                      sudo rm -f "$cli"
                      sudo cp -Pp "$tmp/old-varlatch" "$cli"
                    else
                      rm -f "$cli"
                      cp -Pp "$tmp/old-varlatch" "$cli"
                    fi
                  fi
                  exit 1 ;;
              esac
            elif listed_hash "varlatch-cli-$version.cjs" >/dev/null 2>&1; then
              if [ "$self_sudo" = yes ]; then
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
