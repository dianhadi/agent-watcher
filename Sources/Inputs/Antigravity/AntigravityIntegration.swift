import Foundation
import Darwin

final class AntigravityIntegration: AgentIntegration {
    let id = "antigravity"
    let displayName = "Antigravity"
    private let reconciliationInterval: TimeInterval = 10
    private let newSnapshotGracePeriod: TimeInterval = 30
    private let endedSnapshotLifetime: TimeInterval = 10 * 60
    private var lastReconciliation = Date.distantPast

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
            "SessionEnd": [
                ["type": "command", "command": "\(commandPath) SessionEnd", "timeout": 3]
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

        let statusLineChanged = try installStatusLine(executable: executable)
        return (changed || statusLineChanged)
            ? "Antigravity connected. Restart agy, then run /hooks to review."
            : "Antigravity is connected."
    }

    func uninstall() throws -> String {
        var removed = false
        unlink("/tmp/agent-watcher-antigravity-\(getuid()).sock")
        let home = FileManager.default.homeDirectoryForCurrentUser
        let configDirectory = ProcessInfo.processInfo.environment["GEMINI_CONFIG_DIR"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? home.appendingPathComponent(".gemini/config", isDirectory: true)
        let hooksFile = configDirectory.appendingPathComponent("hooks.json")
        if FileManager.default.fileExists(atPath: hooksFile.path) {
            let data = try Data(contentsOf: hooksFile)
            if var config = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               config.removeValue(forKey: "agent-watcher") != nil {
                try backUpAndWrite(config, file: hooksFile, directory: configDirectory)
                removed = true
            }
        }

        let settingsDirectory = home.appendingPathComponent(".gemini/antigravity-cli", isDirectory: true)
        let settingsFile = settingsDirectory.appendingPathComponent("settings.json")
        if FileManager.default.fileExists(atPath: settingsFile.path) {
            let data = try Data(contentsOf: settingsFile)
            if var settings = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let statusLine = settings["statusLine"] as? [String: Any],
               let command = statusLine["command"] as? String,
               command.contains("Agent Watcher.app"), command.contains("AntigravityHook"),
               command.contains("StatusLine") {
                settings.removeValue(forKey: "statusLine")
                try backUpAndWrite(settings, file: settingsFile, directory: settingsDirectory)
                removed = true
            }
        }
        return removed
            ? "Antigravity disabled. Managed configuration removed; restart agy if it is running."
            : "Antigravity is disabled."
    }

    private func backUpAndWrite(_ object: [String: Any], file: URL, directory: URL) throws {
        let backup = directory.appendingPathComponent(file.lastPathComponent + ".backup-" + UUID().uuidString)
        try FileManager.default.copyItem(at: file, to: backup)
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: file, options: .atomic)
        _ = chmod(file.path, 0o600)
    }

    private func installStatusLine(executable: URL) throws -> Bool {
        let settingsDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/antigravity-cli", isDirectory: true)
        try FileManager.default.createDirectory(at: settingsDirectory, withIntermediateDirectories: true)
        let file = settingsDirectory.appendingPathComponent("settings.json")
        let existed = FileManager.default.fileExists(atPath: file.path)
        var settings: [String: Any] = [:]
        if existed {
            let data = try Data(contentsOf: file)
            if !data.isEmpty {
                guard let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw NSError(domain: "AgentWatcher", code: 3,
                                  userInfo: [NSLocalizedDescriptionKey: "Antigravity settings.json has an invalid format."])
                }
                settings = decoded
            }
        }

        let expectedCommand = "\(shellQuote(executable.path)) StatusLine"
        if var current = settings["statusLine"] as? [String: Any] {
            guard let command = current["command"] as? String,
                  command.contains("AntigravityHook"), command.contains("StatusLine") else {
                // A custom status line belongs to the user; never replace it.
                return false
            }
            guard command != expectedCommand else { return false }
            current["type"] = "command"
            current["command"] = expectedCommand
            settings["statusLine"] = current
        } else {
            settings["statusLine"] = [
                "type": "command",
                "command": expectedCommand,
                "enabled": true,
                "stack_with_default": true
            ]
        }

        if existed {
            let backup = settingsDirectory.appendingPathComponent("settings.json.backup-" + UUID().uuidString)
            try FileManager.default.copyItem(at: file, to: backup)
        }
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: file, options: .atomic)
        _ = chmod(file.path, 0o600)
        return true
    }

    func maintain() {
        let now = Date()
        guard now.timeIntervalSince(lastReconciliation) >= reconciliationInterval else { return }
        lastReconciliation = now
        guard let activeIDs = activeConversationIDs() else { return }

        let folder = StateLocation.current
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil
        ) else { return }
        let decoder = JSONDecoder()
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let snapshot = try? decoder.decode(ActivitySnapshot.self, from: data),
                  snapshot.sourceID == id else { continue }
            let age = now.timeIntervalSince(snapshot.updatedAt)
            let isExpiredEnded = snapshot.state == .ended && age >= endedSnapshotLifetime
            let isInactive = snapshot.state != .ended
                && age >= newSnapshotGracePeriod
                && !activeIDs.contains(snapshot.id)
            if isExpiredEnded {
                try? FileManager.default.removeItem(at: file)
            } else if isInactive {
                writeEndedSnapshot(snapshot, to: file, at: now)
            }
        }
    }

    private func writeEndedSnapshot(_ snapshot: ActivitySnapshot, to file: URL, at date: Date) {
        var object: [String: Any] = [
            "schema_version": 1,
            "id": snapshot.id,
            "source_id": snapshot.sourceID,
            "source_name": snapshot.sourceName,
            "workspace": snapshot.workspace,
            "state": ActivityState.ended.rawValue,
            "updated_at": date.timeIntervalSince1970
        ]
        if let modelName = snapshot.modelName { object["model_name"] = modelName }
        if let detail = snapshot.detail { object["detail"] = detail }
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              (try? data.write(to: file, options: .atomic)) != nil else { return }
        _ = chmod(file.path, 0o600)
    }

    /// Antigravity leaves old presence files behind, so existence alone is not
    /// evidence that a conversation is live. Only locks currently opened by an
    /// `agy` process count as active.
    private func activeConversationIDs() -> Set<String>? {
        let presence = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/antigravity-cli/presence", isDirectory: true)
        guard FileManager.default.fileExists(atPath: presence.path) else { return [] }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        task.arguments = ["-nP", "-F", "n", "-a", "-c", "agy", "+d", presence.path]
        let output = Pipe()
        let errors = Pipe()
        task.standardOutput = output
        task.standardError = errors
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return nil
        }
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        guard errorData.isEmpty else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return Set(text.split(separator: "\n").compactMap { line in
            guard line.first == "n" else { return nil }
            let path = String(line.dropFirst())
            guard path.hasPrefix(presence.path + "/"), path.hasSuffix(".lock") else { return nil }
            return URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        })
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
