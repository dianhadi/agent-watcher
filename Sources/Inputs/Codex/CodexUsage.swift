import Foundation

/// Best-effort reader for the rate-limit metadata Codex records locally.
/// It reads only the tail of recent JSONL files and never retains prompts,
/// commands, responses, or complete session events.
struct CodexUsageProvider: AgentUsageProvider {
    let sourceID = "codex-cli"
    private let maximumFiles = 12
    private let maximumTailBytes: UInt64 = 512 * 1024

    func latestUsage() -> AgentUsageSnapshot? {
        let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
        let sessions = codexHome.appendingPathComponent("sessions", isDirectory: true)

        guard let enumerator = FileManager.default.enumerator(
            at: sessions,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var files: [(url: URL, modified: Date)] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            files.append((url, values.contentModificationDate ?? .distantPast))
        }

        for file in files.sorted(by: { $0.modified > $1.modified }).prefix(maximumFiles) {
            if let limits = rateLimits(inTailOf: file.url),
               let snapshot = snapshot(from: limits, updatedAt: file.modified) {
                return snapshot
            }
        }
        return nil
    }

    private func rateLimits(inTailOf url: URL) -> [String: Any]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return nil }
        let start = end > maximumTailBytes ? end - maximumTailBytes : 0
        do {
            try handle.seek(toOffset: start)
            guard let data = try handle.readToEnd(),
                  let text = String(data: data, encoding: .utf8) else { return nil }
            for line in text.split(separator: "\n").reversed() {
                guard let bytes = String(line).data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: bytes),
                      let limits = findRateLimits(in: object) else { continue }
                return limits
            }
        } catch {
            return nil
        }
        return nil
    }

    private func findRateLimits(in value: Any) -> [String: Any]? {
        if let dictionary = value as? [String: Any] {
            if let limits = dictionary["rate_limits"] as? [String: Any] { return limits }
            for child in dictionary.values {
                if let limits = findRateLimits(in: child) { return limits }
            }
        } else if let array = value as? [Any] {
            for child in array {
                if let limits = findRateLimits(in: child) { return limits }
            }
        }
        return nil
    }

    private func snapshot(from limits: [String: Any], updatedAt: Date) -> AgentUsageSnapshot? {
        let candidates = [
            ("primary", limits["primary"]),
            ("secondary", limits["secondary"])
        ]
        let windows = candidates.compactMap { key, value -> UsageWindow? in
            guard let window = value as? [String: Any],
                  let used = number(window["used_percent"]),
                  let minutes = number(window["window_minutes"]),
                  let reset = number(window["resets_at"]) else { return nil }
            let duration = Int(minutes)
            let name: String
            switch duration {
            case 300: name = "5 hours"
            case 10_080: name = "Weekly"
            default: name = duration >= 60 ? "\(duration / 60) hours" : "\(duration) minutes"
            }
            return UsageWindow(
                id: key,
                name: name,
                usedPercent: used,
                durationMinutes: duration,
                resetsAt: Date(timeIntervalSince1970: reset)
            )
        }
        guard !windows.isEmpty else { return nil }
        return AgentUsageSnapshot(
            sourceID: sourceID,
            sourceName: "Codex CLI",
            planName: limits["plan_type"] as? String,
            windows: windows,
            updatedAt: updatedAt
        )
    }

    private func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }
}
