import Foundation
import Darwin

struct AntigravityIntegration: AgentIntegration {
    let id = "antigravity"
    let displayName = "Antigravity"

    func install() throws -> String {
        guard let executable = resolveExecutable() else {
            throw NSError(domain: "AgentWatcher", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "The AntigravityHook helper is missing from the application bundle."])
        }

        let home = FileManager.default.homeDirectoryForCurrentUser
        let configDir = ProcessInfo.processInfo.environment["GEMINI_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".gemini/config", isDirectory: true)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)

        let file = configDir.appendingPathComponent("hooks.json")
        var config: [String: Any] = [:]
        let existing = FileManager.default.fileExists(atPath: file.path)
        if existing {
            let bytes = try Data(contentsOf: file)
            if !bytes.isEmpty {
                guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
                    throw NSError(domain: "AgentWatcher", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey: "hooks.json has an invalid format."])
                }
                config = object
            }
        }

        let commandPath = shellQuote(executable.path)
        let expectedWatcherConfig: [String: Any] = [
            "enabled": true,
            "SessionStart": [
                ["type": "command", "command": "\(commandPath) SessionStart", "timeout": 3]
            ],
            "PreInvocation": [
                ["type": "command", "command": "\(commandPath) PreInvocation", "timeout": 3]
            ],
            "PostInvocation": [
                ["type": "command", "command": "\(commandPath) PostInvocation", "timeout": 3]
            ],
            "PreToolUse": [
                [
                    "matcher": "*",
                    "hooks": [
                        ["type": "command", "command": "\(commandPath) PreToolUse", "timeout": 3]
                    ]
                ]
            ],
            "PostToolUse": [
                [
                    "matcher": "*",
                    "hooks": [
                        ["type": "command", "command": "\(commandPath) PostToolUse", "timeout": 3]
                    ]
                ]
            ],
            "Stop": [
                ["type": "command", "command": "\(commandPath) Stop", "timeout": 3]
            ]
        ]

        var changed = false
        if let current = config["agent-watcher"] as? [String: Any] {
            if !NSDictionary(dictionary: current).isEqual(to: expectedWatcherConfig) {
                config["agent-watcher"] = expectedWatcherConfig
                changed = true
            }
        } else {
            config["agent-watcher"] = expectedWatcherConfig
            changed = true
        }

        if changed {
            let bytes = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
            if existing {
                let backup = configDir.appendingPathComponent("hooks.json.backup-" + UUID().uuidString)
                try FileManager.default.copyItem(at: file, to: backup)
            }
            try bytes.write(to: file, options: .atomic)
            _ = chmod(file.path, 0o600)
        }

        return changed ? "Antigravity connected. Run /hooks to review." : "Antigravity is connected."
    }

    private func resolveExecutable() -> URL? {
        if let bundleHelper = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("AntigravityHook"),
           FileManager.default.isExecutableFile(atPath: bundleHelper.path) {
            return bundleHelper
        }
        let localHelper = URL(fileURLWithPath: "./AntigravityHook")
        if FileManager.default.isExecutableFile(atPath: localHelper.path) {
            return localHelper.standardizedFileURL
        }
        return nil
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
