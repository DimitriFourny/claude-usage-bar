import Foundation

/// Stores this app's Claude OAuth credentials in the login keychain through `/usr/bin/security`
/// (the same approach Claude Code uses).
///
/// Items created with the Security framework are bound to the creating binary's code signature. This app
/// is ad-hoc signed, so every rebuild is a "different app" and macOS asks for the keychain password again.
/// Items created by the Apple-signed `security` tool trust that tool instead, so access never prompts.
enum Keychain {
    private static let service = "ClaudeUsageBar"
    private static let account = "oauth"

    static func read() -> OAuthCredentials? {
        guard let output = security(["find-generic-password", "-s", service, "-a", account, "-w"]),
              let base64 = String(data: output, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let json = Data(base64Encoded: base64) else { return nil }
        return try? JSONDecoder().decode(OAuthCredentials.self, from: json)
    }

    /// Stores base64(JSON): ASCII only, so `find-generic-password -w` prints it verbatim instead of as hex.
    /// The secret goes through stdin (`security -i`), never argv, so it doesn't show up in `ps`.
    @discardableResult
    static func save(_ credentials: OAuthCredentials) -> Bool {
        guard let json = try? JSONEncoder().encode(credentials) else { return false }
        let hex = Data(json.base64EncodedString().utf8).map { String(format: "%02x", $0) }.joined()
        let command = "add-generic-password -U -s \(service) -a \(account) -X \(hex)\n"
        return security(["-i"], stdin: Data(command.utf8)) != nil
    }

    static func delete() {
        security(["delete-generic-password", "-s", service, "-a", account])
    }

    /// Runs `/usr/bin/security`; returns stdout on exit status 0.
    @discardableResult
    private static func security(_ arguments: [String], stdin: Data? = nil) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let input = Pipe()
        process.standardInput = stdin == nil ? FileHandle.nullDevice : input
        do { try process.run() } catch { return nil }
        if let stdin {
            input.fileHandleForWriting.write(stdin)
            try? input.fileHandleForWriting.close()
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }
}
