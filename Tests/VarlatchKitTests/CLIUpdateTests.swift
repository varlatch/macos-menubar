import CryptoKit
import Foundation
import Testing
@testable import VarlatchKit

struct CLIUpdateTests {
    @Test func choosesTheRightUpdateWay() {
        let p = "/Users/example/.local/bin/varlatch"
        let v23 = Version(0, 23, 0)
        let v50 = Version(0, 50, 0)
        let vRc = Version(0, 50, 0, suffix: "rc.3")
        let vDev = Version(0, 50, 0, suffix: "dev")
        let vRcDev = Version(0, 50, 0, suffix: "rc.1-dev")
        let vOld = Version(0, 10, 9)

        #expect(CLIUpdate.way(kind: .homebrew, path: p, version: v50, isNative: true) == .homebrew)
        #expect(CLIUpdate.way(kind: .homebrew, path: p, version: v23, isNative: false) == .homebrew)
        #expect(CLIUpdate.way(kind: .release, path: p, version: v50, isNative: true) == .selfUpdate)
        #expect(CLIUpdate.way(kind: .release, path: p, version: vRc, isNative: true) == .selfUpdate)
        #expect(CLIUpdate.way(kind: .release, path: p, version: vDev, isNative: true) == .manual)
        #expect(CLIUpdate.way(kind: .release, path: p, version: vRcDev, isNative: true) == .manual)
        #expect(CLIUpdate.way(kind: .release, path: p, version: vOld, isNative: true) == .manual)
        #expect(CLIUpdate.way(kind: .release, path: p, version: v23, isNative: false) == .installer)
        #expect(CLIUpdate.way(kind: .release, path: "/Users/example/bin/varlatch.cjs", version: v23, isNative: false) == .manual)
        #expect(CLIUpdate.way(kind: .release, path: "/Users/example/bin/my-varlatch", version: v23, isNative: false) == .manual)
        #expect(CLIUpdate.way(kind: .checkout, path: p, version: v50, isNative: true) == .manual)
        #expect(CLIUpdate.way(kind: .custom, path: p, version: v50, isNative: true) == .manual)
        #expect(CLIUpdate.way(kind: nil, path: p, version: v50, isNative: true) == .manual)
    }

    @Test func selfUpdateCommandUsesSudoOnlyWhenRootSafeAndNeverNode() {
        let p = "/usr/local/bin/varlatch"
        let v = Version(0, 50, 0)
        let direct = CLIUpdate.selfUpdateCommand(path: p, version: v, writable: true)
        #expect(direct == "'/usr/local/bin/varlatch' self-update '0.50.0'")
        #expect(!direct.contains("sudo"))
        #expect(!direct.contains("node"))

        let elevated = CLIUpdate.selfUpdateCommand(path: p, version: v, writable: false, rootSafe: { _ in true })
        #expect(elevated == "sudo '/usr/local/bin/varlatch' self-update '0.50.0'")
        #expect(!elevated.contains("node"))

        let refused = CLIUpdate.selfUpdateCommand(path: p, version: v, writable: false, rootSafe: { _ in false })
        #expect(refused.contains("refusing to run sudo"))
        #expect(refused.contains("'/usr/local/bin/varlatch' self-update '0.50.0'"))
        #expect(refused.hasSuffix("exit 1"))
    }

    // MARK: Installer script execution tests (fake curl + bash)

    private struct Sandbox {
        let root: URL
        let binDir: URL
        let cliDir: URL
        let releasesDir: URL
        let cliURL: URL
        let logURL: URL

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("vl-update-script-\(UUID().uuidString)")
            binDir = root.appendingPathComponent("bin")
            cliDir = root.appendingPathComponent("cli")
            releasesDir = root.appendingPathComponent("releases")
            cliURL = cliDir.appendingPathComponent("varlatch")
            logURL = root.appendingPathComponent("calls.log")
            for dir in [binDir, cliDir, releasesDir] {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            // Fake curl: serves files from $FAKE_RELEASES/<relpath> for GitHub release URLs.
            let fakeCurl = """
                #!/bin/sh
                out=""
                url=""
                while [ $# -gt 0 ]; do
                  case "$1" in
                    -o) out=$2; shift 2 ;;
                    --proto|--proto-redir|--retry) shift 2 ;;
                    -*) shift ;;
                    *) url=$1; shift ;;
                  esac
                done
                rel=${url#https://github.com/varlatch/varlatch/releases/download/}
                src="$FAKE_RELEASES/$rel"
                [ -f "$src" ] || exit 22
                cp "$src" "$out"
                """
            try writeExecutable(fakeCurl, to: binDir.appendingPathComponent("curl"))

            // Stand-in for the pre-0.50 CLI.
            let oldCLI = """
                #!/bin/sh
                if [ "$1" = "--version" ]; then
                  echo "varlatch 0.23.0 (migration 0)"
                  exit 0
                fi
                echo "old-cli $*" >> \(CLIUpdate.shellQuoted(logURL.path))
                """
            try writeExecutable(oldCLI, to: cliURL)
        }

        func writeExecutable(_ content: String, to url: URL) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }

        func writeFile(_ content: String, to url: URL) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
        }

        func sha256(_ text: String) -> String {
            let digest = SHA256.hash(data: Data(text.utf8))
            return digest.map { String(format: "%02x", $0) }.joined()
        }

        func hostArch() -> String {
            #if arch(arm64)
            return "arm64"
            #else
            return "amd64"
            #endif
        }

        func run(version: Version, input: String = "y\n", needsSudo: Bool = false) throws -> (exitCode: Int32, stdout: String, stderr: String) {
            let script = CLIUpdate.installerScript(path: cliURL.path, version: version, needsSudo: needsSudo)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["-c", script]
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "\(binDir.path):\(env["PATH"] ?? "/usr/bin:/bin")"
            env["FAKE_RELEASES"] = releasesDir.path
            process.environment = env
            let inPipe = Pipe()
            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardInput = inPipe
            process.standardOutput = outPipe
            process.standardError = errPipe
            try process.run()
            if !input.isEmpty {
                try? inPipe.fileHandleForWriting.write(contentsOf: Data(input.utf8))
            }
            try? inPipe.fileHandleForWriting.close()
            let outData = (try? outPipe.fileHandleForReading.readToEnd()) ?? Data()
            let errData = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
            process.waitUntilExit()
            let out = String(decoding: outData, as: UTF8.self)
            let err = String(decoding: errData, as: UTF8.self)
            return (process.terminationStatus, out, err)
        }

        func cliOutput() throws -> String {
            let process = Process()
            process.executableURL = cliURL
            process.arguments = ["--version"]
            let outPipe = Pipe()
            process.standardOutput = outPipe
            try process.run()
            let outData = (try? outPipe.fileHandleForReading.readToEnd()) ?? Data()
            process.waitUntilExit()
            return String(decoding: outData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        func log() -> String {
            (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    @Test func nativeReleaseRunsVerifiedInstallScript() throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let v = Version(0, 50, 0)
        let releaseDir = box.releasesDir.appendingPathComponent("v0.50.0")
        let fakeInstall = """
            #!/bin/sh
            echo "install.sh $*" >> \(CLIUpdate.shellQuoted(box.logURL.path))
            dir=""
            ver=""
            while [ $# -gt 0 ]; do
              case "$1" in
                --dir) dir=$2; shift 2 ;;
                --version) ver=$2; shift 2 ;;
                *) shift ;;
              esac
            done
            cat > "$dir/varlatch" <<EOF
            #!/bin/sh
            echo "varlatch $ver"
            EOF
            chmod 755 "$dir/varlatch"
            """
        try box.writeFile(fakeInstall, to: releaseDir.appendingPathComponent("install.sh"))
        let sums = """
            \(String(repeating: "a", count: 64))  varlatch-0.50.0-darwin-\(box.hostArch())
            \(box.sha256(fakeInstall))  install.sh
            """
        try box.writeFile(sums + "\n", to: releaseDir.appendingPathComponent("SHA256SUMS"))

        let res = try box.run(version: v, input: "y\n")
        #expect(res.exitCode == 0)
        #expect(res.stdout.contains("checksum: ok (SHA256SUMS)"))
        #expect(try box.cliOutput() == "varlatch 0.50.0")
        #expect(box.log().contains("install.sh --version 0.50.0 --dir \(box.cliDir.path)"))
        #expect(!box.log().contains("old-cli"))
    }

    @Test func nativeReleaseDeclinedLeavesOldCLI() throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let v = Version(0, 50, 0)
        let releaseDir = box.releasesDir.appendingPathComponent("v0.50.0")
        let fakeInstall = "#!/bin/sh\necho ran >> \(CLIUpdate.shellQuoted(box.logURL.path))\n"
        try box.writeFile(fakeInstall, to: releaseDir.appendingPathComponent("install.sh"))
        let sums = """
            \(String(repeating: "a", count: 64))  varlatch-0.50.0-darwin-\(box.hostArch())
            \(box.sha256(fakeInstall))  install.sh
            """
        try box.writeFile(sums + "\n", to: releaseDir.appendingPathComponent("SHA256SUMS"))

        let res = try box.run(version: v, input: "n\n")
        #expect(res.exitCode == 130)
        #expect(try box.cliOutput() == "varlatch 0.23.0 (migration 0)")
        #expect(box.log().isEmpty)
    }

    @Test func pre050ReleaseRunsSelfUpdate() throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let v = Version(0, 24, 0)
        let releaseDir = box.releasesDir.appendingPathComponent("v0.24.0")
        let sums = "\(String(repeating: "b", count: 64))  varlatch-cli-0.24.0.cjs\n"
        try box.writeFile(sums, to: releaseDir.appendingPathComponent("SHA256SUMS"))

        let res = try box.run(version: v)
        #expect(res.exitCode == 0)
        #expect(box.log().contains("old-cli self-update 0.24.0"))
    }

    @Test func missingInstallScriptChecksumRefuses() throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let v = Version(0, 50, 0)
        let releaseDir = box.releasesDir.appendingPathComponent("v0.50.0")
        let sums = "\(String(repeating: "a", count: 64))  varlatch-0.50.0-darwin-\(box.hostArch())\n"
        try box.writeFile(sums, to: releaseDir.appendingPathComponent("SHA256SUMS"))

        let res = try box.run(version: v)
        #expect(res.exitCode != 0)
        #expect(res.stderr.contains("install.sh"))
        #expect(try box.cliOutput() == "varlatch 0.23.0 (migration 0)")
    }

    @Test func mismatchingInstallScriptChecksumRefusesWithoutRunning() throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let v = Version(0, 50, 0)
        let releaseDir = box.releasesDir.appendingPathComponent("v0.50.0")
        let fakeInstall = "#!/bin/sh\necho bad-ran >> \(CLIUpdate.shellQuoted(box.logURL.path))\n"
        try box.writeFile(fakeInstall, to: releaseDir.appendingPathComponent("install.sh"))
        let sums = """
            \(String(repeating: "a", count: 64))  varlatch-0.50.0-darwin-\(box.hostArch())
            \(String(repeating: "0", count: 64))  install.sh
            """
        try box.writeFile(sums + "\n", to: releaseDir.appendingPathComponent("SHA256SUMS"))

        let res = try box.run(version: v)
        #expect(res.exitCode != 0)
        #expect(res.stderr.contains("does not match SHA256SUMS"))
        #expect(box.log().isEmpty)
        #expect(try box.cliOutput() == "varlatch 0.23.0 (migration 0)")
    }

    @Test func sudoDecisionMatchesDirectoryEachUpdaterWrites() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vl-sudo-dir-\(UUID().uuidString)")
        let roDir = root.appendingPathComponent("ro")
        let rwDir = root.appendingPathComponent("rw")
        try FileManager.default.createDirectory(at: roDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: rwDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: roDir.path)
            try? FileManager.default.removeItem(at: root)
        }
        let target = roDir.appendingPathComponent("varlatch-real")
        try Data([0xcf, 0xfa, 0xed, 0xfe]).write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: roDir.path)
        let link = rwDir.appendingPathComponent("varlatch")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target.path)

        let v = Version(0, 50, 0)
        // Native updater writes beside the resolved file (roDir -> needs sudo,
        // and only elevates when the target and directory are root-safe).
        #expect(CLIUpdate.selfUpdateCommand(path: link.path, version: v, rootSafe: { _ in true }).hasPrefix("sudo "))
        #expect(CLIUpdate.selfUpdateCommand(path: link.path, version: v).contains("refusing to run sudo"))
        // TypeScript installer script writes to the invoked path's directory (rwDir -> no sudo).
        #expect(CLIUpdate.installerScript(path: link.path, version: v).contains("use_sudo=no"))
    }

    @Test func brokenReplacementRestoresOldCLI() throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let v = Version(0, 50, 0)
        let releaseDir = box.releasesDir.appendingPathComponent("v0.50.0")
        let fakeInstall = """
            #!/bin/sh
            dir=""
            while [ $# -gt 0 ]; do
              case "$1" in
                --dir) dir=$2; shift 2 ;;
                --version) shift 2 ;;
                *) shift ;;
              esac
            done
            printf '#!/bin/sh\\nexit 126\\n' > "$dir/varlatch"
            chmod 755 "$dir/varlatch"
            """
        try box.writeFile(fakeInstall, to: releaseDir.appendingPathComponent("install.sh"))
        let sums = """
            \(String(repeating: "a", count: 64))  varlatch-0.50.0-darwin-\(box.hostArch())
            \(box.sha256(fakeInstall))  install.sh
            """
        try box.writeFile(sums + "\n", to: releaseDir.appendingPathComponent("SHA256SUMS"))

        let res = try box.run(version: v, input: "y\n")
        #expect(res.exitCode != 0)
        #expect(res.stderr.contains("the old CLI is back"))
        #expect(try box.cliOutput() == "varlatch 0.23.0 (migration 0)")
    }

    @Test func failingInstallerThatCorruptsTargetStillRollsBack() throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let v = Version(0, 50, 0)
        let releaseDir = box.releasesDir.appendingPathComponent("v0.50.0")
        let fakeInstall = """
            #!/bin/sh
            dir=""
            while [ $# -gt 0 ]; do
              case "$1" in
                --dir) dir=$2; shift 2 ;;
                --version) shift 2 ;;
                *) shift ;;
              esac
            done
            printf '#!/bin/sh\\nexit 126\\n' > "$dir/varlatch"
            chmod 755 "$dir/varlatch"
            exit 1
            """
        try box.writeFile(fakeInstall, to: releaseDir.appendingPathComponent("install.sh"))
        let sums = """
            \(String(repeating: "a", count: 64))  varlatch-0.50.0-darwin-\(box.hostArch())
            \(box.sha256(fakeInstall))  install.sh
            """
        try box.writeFile(sums + "\n", to: releaseDir.appendingPathComponent("SHA256SUMS"))

        let res = try box.run(version: v, input: "y\n")
        #expect(res.exitCode != 0)
        #expect(res.stderr.contains("the old CLI is back"))
        #expect(try box.cliOutput() == "varlatch 0.23.0 (migration 0)")
    }

    @Test func homebrewOnPathWarnsBeforeAsking() throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        // Place a Homebrew-marked varlatch on PATH (in box.binDir).
        try box.writeExecutable("#!/bin/sh\n# installed with Homebrew\necho 'varlatch 0.23.0'\n",
                                to: box.binDir.appendingPathComponent("varlatch"))
        let v = Version(0, 50, 0)
        let releaseDir = box.releasesDir.appendingPathComponent("v0.50.0")
        let fakeInstall = "#!/bin/sh\necho ran >> \(CLIUpdate.shellQuoted(box.logURL.path))\n"
        try box.writeFile(fakeInstall, to: releaseDir.appendingPathComponent("install.sh"))
        let sums = """
            \(String(repeating: "a", count: 64))  varlatch-0.50.0-darwin-\(box.hostArch())
            \(box.sha256(fakeInstall))  install.sh
            """
        try box.writeFile(sums + "\n", to: releaseDir.appendingPathComponent("SHA256SUMS"))

        let res = try box.run(version: v, input: "")
        #expect(res.exitCode != 0)
        #expect(res.stderr.contains("brew upgrade varlatch"))
        #expect(!res.stdout.contains("Install?"))
        #expect(box.log().isEmpty)
        #expect(try box.cliOutput() == "varlatch 0.23.0 (migration 0)")
    }

    @Test func homebrewMultiHopSymlinkDetectedWithoutPython() throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        // Stub python3 to fail loudly if invoked.
        try box.writeExecutable("#!/bin/sh\necho python-called >> \(CLIUpdate.shellQuoted(box.logURL.path))\nexit 99\n",
                                to: box.binDir.appendingPathComponent("python3"))
        let target = box.root.appendingPathComponent("real-brew/varlatch")
        try box.writeExecutable("#!/bin/sh\n# installed with Homebrew\necho 'varlatch 0.23.0'\n", to: target)
        let hop1 = box.root.appendingPathComponent("hop1")
        try FileManager.default.createSymbolicLink(atPath: hop1.path, withDestinationPath: target.path)
        let link = box.binDir.appendingPathComponent("varlatch")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: hop1.path)

        let v = Version(0, 50, 0)
        let releaseDir = box.releasesDir.appendingPathComponent("v0.50.0")
        let fakeInstall = "#!/bin/sh\necho ran >> \(CLIUpdate.shellQuoted(box.logURL.path))\n"
        try box.writeFile(fakeInstall, to: releaseDir.appendingPathComponent("install.sh"))
        let sums = """
            \(String(repeating: "a", count: 64))  varlatch-0.50.0-darwin-\(box.hostArch())
            \(box.sha256(fakeInstall))  install.sh
            """
        try box.writeFile(sums + "\n", to: releaseDir.appendingPathComponent("SHA256SUMS"))

        let res = try box.run(version: v, input: "")
        #expect(res.exitCode != 0)
        #expect(res.stderr.contains("brew upgrade varlatch"))
        #expect(box.log().isEmpty)
    }

    @Test func nativeBinaryContainingHomebrewStringOnPathIsNotBlocked() throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        var bytes: [UInt8] = [0xcf, 0xfa, 0xed, 0xfe, 0, 0, 0, 0]
        bytes.append(contentsOf: Array("installed with Homebrew\n".utf8))
        let binOnPath = box.binDir.appendingPathComponent("varlatch")
        try Data(bytes).write(to: binOnPath)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binOnPath.path)

        let v = Version(0, 50, 0)
        let releaseDir = box.releasesDir.appendingPathComponent("v0.50.0")
        let fakeInstall = """
            #!/bin/sh
            dir=""
            ver=""
            while [ $# -gt 0 ]; do
              case "$1" in
                --dir) dir=$2; shift 2 ;;
                --version) ver=$2; shift 2 ;;
                *) shift ;;
              esac
            done
            printf '#!/bin/sh\\necho "varlatch %s"\\n' "$ver" > "$dir/varlatch"
            chmod 755 "$dir/varlatch"
            """
        try box.writeFile(fakeInstall, to: releaseDir.appendingPathComponent("install.sh"))
        let sums = """
            \(String(repeating: "a", count: 64))  varlatch-0.50.0-darwin-\(box.hostArch())
            \(box.sha256(fakeInstall))  install.sh
            """
        try box.writeFile(sums + "\n", to: releaseDir.appendingPathComponent("SHA256SUMS"))

        let res = try box.run(version: v, input: "y\n")
        #expect(res.exitCode == 0)
        #expect(try box.cliOutput() == "varlatch 0.50.0")
    }

    @Test func nonZeroVersionExitWithMatchingStdoutRestoresOldCLI() throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let v = Version(0, 50, 0)
        let releaseDir = box.releasesDir.appendingPathComponent("v0.50.0")
        let fakeInstall = """
            #!/bin/sh
            dir=""
            ver=""
            while [ $# -gt 0 ]; do
              case "$1" in
                --dir) dir=$2; shift 2 ;;
                --version) ver=$2; shift 2 ;;
                *) shift ;;
              esac
            done
            printf '#!/bin/sh\\necho "varlatch %s"\\nexit 2\\n' "$ver" > "$dir/varlatch"
            chmod 755 "$dir/varlatch"
            """
        try box.writeFile(fakeInstall, to: releaseDir.appendingPathComponent("install.sh"))
        let sums = """
            \(String(repeating: "a", count: 64))  varlatch-0.50.0-darwin-\(box.hostArch())
            \(box.sha256(fakeInstall))  install.sh
            """
        try box.writeFile(sums + "\n", to: releaseDir.appendingPathComponent("SHA256SUMS"))

        let res = try box.run(version: v, input: "y\n")
        #expect(res.exitCode != 0)
        #expect(res.stderr.contains("exited 2"))
        #expect(res.stderr.contains("the old CLI is back"))
        #expect(try box.cliOutput() == "varlatch 0.23.0 (migration 0)")
    }

    @Test func cosignVerifiesManifestBeforeRunningInstaller() throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let fakeCosign = """
            #!/bin/sh
            echo "cosign $*" >> \(CLIUpdate.shellQuoted(box.logURL.path))
            id=""
            iss=""
            while [ $# -gt 0 ]; do
              case "$1" in
                --certificate-identity) id=$2; shift 2 ;;
                --certificate-oidc-issuer) iss=$2; shift 2 ;;
                *) shift ;;
              esac
            done
            [ "$id" = "https://github.com/varlatch/varlatch/.github/workflows/release.yml@refs/tags/v0.50.0" ] || exit 1
            [ "$iss" = "https://token.actions.githubusercontent.com" ] || exit 1
            exit 0
            """
        try box.writeExecutable(fakeCosign, to: box.binDir.appendingPathComponent("cosign"))

        let v = Version(0, 50, 0)
        let releaseDir = box.releasesDir.appendingPathComponent("v0.50.0")
        let fakeInstall = """
            #!/bin/sh
            echo "install.sh $*" >> \(CLIUpdate.shellQuoted(box.logURL.path))
            dir=""
            ver=""
            while [ $# -gt 0 ]; do
              case "$1" in
                --dir) dir=$2; shift 2 ;;
                --version) ver=$2; shift 2 ;;
                *) shift ;;
              esac
            done
            printf '#!/bin/sh\\necho "varlatch %s"\\n' "$ver" > "$dir/varlatch"
            chmod 755 "$dir/varlatch"
            """
        try box.writeFile(fakeInstall, to: releaseDir.appendingPathComponent("install.sh"))
        try box.writeFile("{}", to: releaseDir.appendingPathComponent("SHA256SUMS.sigstore.json"))
        let sums = """
            \(String(repeating: "a", count: 64))  varlatch-0.50.0-darwin-\(box.hostArch())
            \(box.sha256(fakeInstall))  install.sh
            """
        try box.writeFile(sums + "\n", to: releaseDir.appendingPathComponent("SHA256SUMS"))

        let res = try box.run(version: v, input: "y\n")
        #expect(res.exitCode == 0)
        let log = box.log()
        let cosignIdx = try #require(log.range(of: "cosign verify-blob")?.lowerBound)
        let installIdx = try #require(log.range(of: "install.sh")?.lowerBound)
        #expect(cosignIdx < installIdx)
        #expect(try box.cliOutput() == "varlatch 0.50.0")
    }

    @Test func cosignFailureRefusesWithoutRunningInstaller() throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        try box.writeExecutable("#!/bin/sh\nexit 1\n", to: box.binDir.appendingPathComponent("cosign"))

        let v = Version(0, 50, 0)
        let releaseDir = box.releasesDir.appendingPathComponent("v0.50.0")
        let fakeInstall = "#!/bin/sh\necho bad-ran >> \(CLIUpdate.shellQuoted(box.logURL.path))\n"
        try box.writeFile(fakeInstall, to: releaseDir.appendingPathComponent("install.sh"))
        try box.writeFile("{}", to: releaseDir.appendingPathComponent("SHA256SUMS.sigstore.json"))
        let sums = """
            \(String(repeating: "a", count: 64))  varlatch-0.50.0-darwin-\(box.hostArch())
            \(box.sha256(fakeInstall))  install.sh
            """
        try box.writeFile(sums + "\n", to: releaseDir.appendingPathComponent("SHA256SUMS"))

        let res = try box.run(version: v, input: "y\n")
        #expect(res.exitCode != 0)
        #expect(res.stderr.contains("cosign signature verification"))
        #expect(box.log().isEmpty)
        #expect(try box.cliOutput() == "varlatch 0.23.0 (migration 0)")
    }

    @Test func cosignMissingBundleRefusesWithoutRunningInstaller() throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        try box.writeExecutable("#!/bin/sh\nexit 0\n", to: box.binDir.appendingPathComponent("cosign"))

        let v = Version(0, 50, 0)
        let releaseDir = box.releasesDir.appendingPathComponent("v0.50.0")
        let fakeInstall = "#!/bin/sh\necho bad-ran >> \(CLIUpdate.shellQuoted(box.logURL.path))\n"
        try box.writeFile(fakeInstall, to: releaseDir.appendingPathComponent("install.sh"))
        let sums = """
            \(String(repeating: "a", count: 64))  varlatch-0.50.0-darwin-\(box.hostArch())
            \(box.sha256(fakeInstall))  install.sh
            """
        try box.writeFile(sums + "\n", to: releaseDir.appendingPathComponent("SHA256SUMS"))

        let res = try box.run(version: v, input: "y\n")
        #expect(res.exitCode != 0)
        #expect(res.stderr.contains("SHA256SUMS.sigstore.json"))
        #expect(box.log().isEmpty)
        #expect(try box.cliOutput() == "varlatch 0.23.0 (migration 0)")
    }

    @Test func installerScriptRefusesSudoOnNonRootDir() throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let v = Version(0, 50, 0)
        let releaseDir = box.releasesDir.appendingPathComponent("v0.50.0")
        let fakeInstall = "#!/bin/sh\necho bad-ran >> \(CLIUpdate.shellQuoted(box.logURL.path))\n"
        try box.writeFile(fakeInstall, to: releaseDir.appendingPathComponent("install.sh"))
        let sums = """
            \(String(repeating: "a", count: 64))  varlatch-0.50.0-darwin-\(box.hostArch())
            \(box.sha256(fakeInstall))  install.sh
            """
        try box.writeFile(sums + "\n", to: releaseDir.appendingPathComponent("SHA256SUMS"))

        let res = try box.run(version: v, input: "y\n", needsSudo: true)
        #expect(res.exitCode != 0)
        #expect(res.stderr.contains("refusing to run sudo"))
        #expect(box.log().isEmpty)
        #expect(try box.cliOutput() == "varlatch 0.23.0 (migration 0)")
    }
}
