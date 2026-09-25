import Foundation

enum ActivityState: String, Decodable {
    case needsAttention = "needs_attention"
    case running
    case idle
    case ended
    case unknown

    init(snapshotValue: String) {
        switch snapshotValue {
        case "approval", "needs_attention": self = .needsAttention
        case "running": self = .running
        case "standby", "idle": self = .idle
        case "ended": self = .ended
        default: self = .unknown
        }
    }
}

/// Agent-neutral snapshot persisted by an integration adapter.
/// Additional integrations only need to emit this contract; the UI does not need
/// to understand their native event format.
struct ActivitySnapshot: Decodable, Identifiable {
    let id: String
    let sourceID: String
    let sourceName: String
    let workspace: String
    let state: ActivityState
    let detail: String?
    let updatedAt: Date

    var project: String {
        workspace.isEmpty ? sourceName : URL(fileURLWithPath: workspace).lastPathComponent
    }

    private enum CodingKeys: String, CodingKey {
        case id, sourceID = "source_id", sourceName = "source_name"
        case workspace, state, detail, updatedAt = "updated_at"
        // Version 0 compatibility (Codex Sentinel).
        case sessionID = "session_id", cwd, status, tool
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(String.self, forKey: .id)
            ?? values.decode(String.self, forKey: .sessionID)
        sourceID = try values.decodeIfPresent(String.self, forKey: .sourceID) ?? "codex-cli"
        sourceName = try values.decodeIfPresent(String.self, forKey: .sourceName) ?? "Codex CLI"
        workspace = try values.decodeIfPresent(String.self, forKey: .workspace)
            ?? values.decodeIfPresent(String.self, forKey: .cwd) ?? ""
        let rawState = try values.decodeIfPresent(String.self, forKey: .state)
            ?? values.decodeIfPresent(String.self, forKey: .status) ?? "unknown"
        state = ActivityState(snapshotValue: rawState)
        detail = try values.decodeIfPresent(String.self, forKey: .detail)
            ?? values.decodeIfPresent(String.self, forKey: .tool)
        updatedAt = Date(timeIntervalSince1970: try values.decode(Double.self, forKey: .updatedAt))
    }
}

/// A small, device-neutral signal derived from all current activities.
/// A menu bar, USB light, notification service, or future output can render it.
enum AttentionSignal: String {
    case inactive
    case idle
    case active
    case partialAttention
    case fullAttention
}

struct ActivitySummary {
    let activities: [ActivitySnapshot]

    func count(_ state: ActivityState) -> Int {
        activities.filter { currentState(of: $0) == state }.count
    }

    func currentState(of activity: ActivitySnapshot, now: Date = Date()) -> ActivityState {
        guard activity.state != .ended else { return .ended }
        return now.timeIntervalSince(activity.updatedAt) > 12 * 3600 ? .unknown : activity.state
    }

    var signal: AttentionSignal {
        let waiting = count(.needsAttention)
        let total = waiting + count(.running) + count(.idle)
        if total == 0 { return .inactive }
        if waiting == total { return .fullAttention }
        if waiting > 0 { return .partialAttention }
        if count(.running) > 0 { return .active }
        return .idle
    }
}

protocol AgentIntegration {
    var id: String { get }
    var displayName: String { get }
    func install() throws -> String
}

/// Optional destination for the aggregate status. The application has no
/// required output: its window and menu bar work without any implementation.
protocol ActivityOutput {
    var id: String { get }
    var displayName: String { get }
    func publish(_ signal: AttentionSignal) throws
}

enum StateLocation {
    static var current: URL {
        if let value = ProcessInfo.processInfo.environment["AGENT_WATCHER_STATE_DIR"] {
            return URL(fileURLWithPath: value, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Agent Watcher/activities", isDirectory: true)
    }

    static var legacy: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Codex Sentinel/sessions", isDirectory: true)
    }
}
