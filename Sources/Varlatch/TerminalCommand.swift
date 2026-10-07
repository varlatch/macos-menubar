import AppKit

/// Runs a command in a new Terminal window: a temporary `.command` file,
/// opened like any document. Unlike scripting Terminal, this needs no
/// Automation permission. The file removes itself.
enum TerminalCommand {
    /// - Parameters:
    ///   - title: what the window says it does.
    ///   - command: the shell command, shown before it runs.
    static func run(title: String, command: String) {
        let script = """
            #!/bin/bash
            rm -f "$0"
            echo \(shellQuoted(title))
            echo
            echo \(shellQuoted("$ " + command))
            \(command)
            status=$?
            echo
            if [ "$status" -eq 0 ]; then echo "Done. You can close this window."; else echo "That did not work (exit $status)."; fi

            """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("varlatch-\(UUID().uuidString.prefix(8)).command")
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            NSWorkspace.shared.open(url)
        } catch {
            NSLog("Varlatch: cannot write \(url.path): \(error)")
        }
    }

    /// 'text' for a shell, with single quotes inside escaped.
    static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
