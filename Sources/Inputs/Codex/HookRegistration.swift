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
                          userInfo: [NSLocalizedDescriptionKey: "The CodexHook helper is missing from the application bundle."])
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
                              userInfo: [NSLocalizedDescriptionKey: "hooks.json has an invalid format."])
            }
            config = object
        }
        var hooks: [String: Any] = [:]
        if let hooksValue = config["hooks"] {
            guard let existingHooks = hooksValue as? [String: Any] else {
                throw NSError(domain: "AgentWatcher", code: 4,
                              userInfo: [NSLocalizedDescriptionKey: "hooks.json has an invalid structure."])
            }
            hooks = existingHooks
        }
        let command = shellQuote(executable.path)
        var changed = false
        for event in Self.events {
            var groups: [[String: Any]] = []
            if let value = hooks[event] {
                guard let existingGroups = value as? [[String: Any]] else {
                    throw NSError(domain: "AgentWatcher", code: 3,
                                  userInfo: [NSLocalizedDescriptionKey: "hooks.\(event) has an invalid structure."])
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
        return changed ? "Codex CLI connected. Run /hooks to review and trust it." : "Codex CLI is connected."
    }

    func uninstall() throws -> String {
        let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
        let file = codexHome.appendingPathComponent("hooks.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return "Codex CLI is disabled." }
        let data = try Data(contentsOf: file)
        guard var config = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var hooks = config["hooks"] as? [String: Any] else { return "Codex CLI is disabled." }
        var changed = false
        for event in Self.events {
            guard let groups = hooks[event] as? [[String: Any]] else { continue }
            let cleaned = groups.compactMap { group -> [String: Any]? in
                guard let handlers = group["hooks"] as? [[String: Any]] else { return group }
                let remaining = handlers.filter { handler in
                    guard let command = handler["command"] as? String else { return true }
                    return !(command.contains("Agent Watcher.app") && command.contains("CodexHook"))
                }
                if remaining.count != handlers.count { changed = true }
                guard !remaining.isEmpty else { return nil }
                var updated = group
                updated["hooks"] = remaining
                return updated
            }
            if cleaned.isEmpty { hooks.removeValue(forKey: event) }
            else { hooks[event] = cleaned }
        }
        guard changed else { return "Codex CLI is disabled." }
        config["hooks"] = hooks
        let backup = codexHome.appendingPathComponent("hooks.json.backup-" + UUID().uuidString)
        try FileManager.default.copyItem(at: file, to: backup)
        let updated = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
        try updated.write(to: file, options: .atomic)
        _ = chmod(file.path, 0o600)
        return "Codex CLI disabled. Managed hooks removed."
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
