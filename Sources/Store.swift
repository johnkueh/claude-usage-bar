import Foundation

// Thin wrapper around the claude-account world: snapshot files in ~/.claude,
// the live keychain credential, and the claude-account CLI for switching.
enum AccountStore {
    static let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    static let cli = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/bin/claude-account").path

    static func accounts() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { $0.hasPrefix(".cred-") }.map { String($0.dropFirst(".cred-".count)) }.sorted()
    }

    static func activeAccount() -> String? {
        let marker = dir.appendingPathComponent(".account-active")
        return (try? String(contentsOf: marker, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @discardableResult
    static func run(_ path: String, _ args: [String]) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, "\(error.localizedDescription)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    // The live credential is read via /usr/bin/security (not the Keychain API)
    // so the existing keychain ACL — which already trusts `security` — applies
    // and the app never triggers its own access prompt.
    static func liveCredential() -> String? {
        let (status, out) = run("/usr/bin/security",
            ["find-generic-password", "-w", "-s", "Claude Code-credentials", "-a", NSUserName()])
        let blob = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return status == 0 && !blob.isEmpty ? blob : nil
    }

    static func token(for name: String) -> String? {
        let blob: String?
        if name == activeAccount() {
            blob = liveCredential()
        } else {
            blob = try? String(contentsOf: dir.appendingPathComponent(".cred-\(name)"), encoding: .utf8)
        }
        guard let blob, let data = blob.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty
        else { return nil }
        return token
    }

    static func switchTo(_ name: String) -> (ok: Bool, output: String) {
        let (status, out) = run(cli, [name])
        return (status == 0, out)
    }

    static func snapshot(_ name: String) -> (ok: Bool, output: String) {
        let (status, out) = run(cli, ["snapshot", name])
        return (status == 0, out)
    }

    static func remove(_ name: String) throws {
        try FileManager.default.removeItem(at: dir.appendingPathComponent(".cred-\(name)"))
    }

    static func notify(title: String, message: String) {
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "\"", with: "\\\"") }
        run("/usr/bin/osascript", ["-e",
            "display notification \"\(esc(message))\" with title \"\(esc(title))\""])
    }
}
