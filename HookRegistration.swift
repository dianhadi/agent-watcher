import Foundation
import Darwin

struct CodexCLIIntegration: AgentIntegration {
    let id = "codex-cli"
    let displayName = "Codex CLI"

    static let events = [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
        "PermissionRequest", "Stop", "Interrupt", "SessionEnd"
    ]

    func install() throws -> String {
        guard let executable = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("CodexHook"),
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw NSError(domain: "AgentWatcher", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Helper CodexHook tidak ada di paket aplikasi."])
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        let file = codexHome.appendingPathComponent("hooks.json")
        var config: [String: Any] = [:]
        let existing = FileManager.default.fileExists(atPath: file.path)
        if existing {
            let bytes = try Data(contentsOf: file)
            guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
                throw NSError(domain: "AgentWatcher", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "Format hooks.json tidak valid."])
            }
            config = object
        }
        var hooks: [String: Any] = [:]
        if let hooksValue = config["hooks"] {
            guard let existingHooks = hooksValue as? [String: Any] else {
                throw NSError(domain: "AgentWatcher", code: 4,
                              userInfo: [NSLocalizedDescriptionKey: "Struktur hooks.json tidak valid."])
            }
            hooks = existingHooks
        }
        let command = shellQuote(executable.path)
        var changed = false
        for event in events {
            var groups: [[String: Any]] = []
            if let value = hooks[event] {
                guard let existingGroups = value as? [[String: Any]] else {
                    throw NSError(domain: "AgentWatcher", code: 3,
                                  userInfo: [NSLocalizedDescriptionKey: "Struktur hooks.\(event) tidak valid."])
                }
                groups = existingGroups
            }
            let alreadyInstalled = groups.contains { group in
                (group["hooks"] as? [[String: Any]])?.contains {
                    ($0["command"] as? String) == command
                } ?? false
            }
            if !alreadyInstalled {
                groups.append(["hooks": [["type": "command", "command": command, "timeout": 3]]])
                hooks[event] = groups
                changed = true
            }
        }
        if changed {
            config["hooks"] = hooks
            let bytes = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
            if existing {
                let backup = codexHome.appendingPathComponent("hooks.json.backup-" + UUID().uuidString)
                try FileManager.default.copyItem(at: file, to: backup)
            }
            try bytes.write(to: file, options: .atomic)
            _ = chmod(file.path, 0o600)
        }
        return changed ? "Codex CLI terhubung. Jalankan /hooks untuk mempercayainya." : "Codex CLI sudah terhubung."
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
