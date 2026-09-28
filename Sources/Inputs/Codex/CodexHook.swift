import Foundation
import Darwin

// Minimal CLI executable installed inside the app bundle. It never records prompts,
// commands, model output, or the complete event payload.
let statuses = [
    "SessionStart": "standby",
    "UserPromptSubmit": "running",
    "PreToolUse": "running",
    "PostToolUse": "running",
    "PermissionRequest": "approval",
    "Stop": "standby",
    "Interrupt": "standby",
    "SessionEnd": "ended"
]

do {
    let input = FileHandle.standardInput.readDataToEndOfFile()
    guard let payload = try JSONSerialization.jsonObject(with: input) as? [String: Any],
          let event = payload["hook_event_name"] as? String,
          let state = statuses[event],
          let id = payload["session_id"] as? String, !id.isEmpty else {
        exit(0)
    }
    let safeID = String(id.unicodeScalars.filter {
        CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
    })
    guard !safeID.isEmpty else { exit(0) }
    let folder = ProcessInfo.processInfo.environment["AGENT_WATCHER_STATE_DIR"].map {
        URL(fileURLWithPath: $0, isDirectory: true)
    } ?? FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Agent Watcher/activities", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let snapshot: [String: Any] = [
        "schema_version": 1,
        "id": id,
        "source_id": "codex-cli",
        "source_name": "Codex CLI",
        "workspace": payload["cwd"] as? String ?? "",
        "state": state == "approval" ? "needs_attention" : (state == "standby" ? "idle" : state),
        "detail": event == "PermissionRequest" ? (payload["tool_name"] as? String ?? "") : "",
        "updated_at": Date().timeIntervalSince1970
    ]
    let bytes = try JSONSerialization.data(withJSONObject: snapshot)
    let target = folder.appendingPathComponent(safeID + ".json")
    try bytes.write(to: target, options: .atomic)
    _ = chmod(target.path, 0o600)
} catch {
    // Status reporting must never block Codex.
}
