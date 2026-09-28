import Foundation
import Darwin

var stdoutResponse = "{}"

func finishAndExit(_ code: Int32 = 0) -> Never {
    if let data = (stdoutResponse + "\n").data(using: .utf8) {
        FileHandle.standardOutput.write(data)
    }
    exit(code)
}

do {
    let eventArg = CommandLine.arguments.dropFirst().first

    let input = FileHandle.standardInput.readDataToEndOfFile()
    guard !input.isEmpty,
          let payload = try JSONSerialization.jsonObject(with: input) as? [String: Any] else {
        finishAndExit(0)
    }

    var event = eventArg ?? ""
    if event.isEmpty {
        if payload["toolCall"] != nil {
            event = "PreToolUse"
        } else if payload["terminationReason"] != nil {
            event = "Stop"
        } else if payload["invocationNum"] != nil {
            event = "PreInvocation"
        } else if payload["stepIdx"] != nil {
            event = "PostToolUse"
        } else {
            event = "PreInvocation"
        }
    }

    let id = (payload["conversationId"] as? String)
        ?? (payload["id"] as? String)
        ?? (payload["session_id"] as? String)
        ?? ""

    guard !id.isEmpty else {
        finishAndExit(0)
    }

    let safeID = String(id.unicodeScalars.filter {
        CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
    })
    guard !safeID.isEmpty else {
        finishAndExit(0)
    }

    let workspacePaths = payload["workspacePaths"] as? [String] ?? []
    let workspace = workspacePaths.first
        ?? (payload["workspace"] as? String)
        ?? (payload["cwd"] as? String)
        ?? ""

    var state = "running"
    var detail: String? = nil

    switch event {
    case "SessionStart":
        state = "idle"
    case "PreInvocation", "PostInvocation":
        state = "running"
    case "PreToolUse":
        let toolCall = payload["toolCall"] as? [String: Any]
        let toolName = toolCall?["name"] as? String
            ?? (payload["tool_name"] as? String)
            ?? "tool approval"
        state = "needs_attention"
        detail = toolName
    case "PostToolUse":
        state = "running"
    case "Stop":
        state = "idle"
    default:
        state = "running"
    }

    let folder = ProcessInfo.processInfo.environment["AGENT_WATCHER_STATE_DIR"].map {
        URL(fileURLWithPath: $0, isDirectory: true)
    } ?? FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Agent Watcher/activities", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

    var snapshot: [String: Any] = [
        "schema_version": 1,
        "id": id,
        "source_id": "antigravity",
        "source_name": "Antigravity",
        "workspace": workspace,
        "state": state,
        "updated_at": Date().timeIntervalSince1970
    ]
    if let detail = detail {
        snapshot["detail"] = detail
    }

    let bytes = try JSONSerialization.data(withJSONObject: snapshot)
    let target = folder.appendingPathComponent(safeID + ".json")
    try bytes.write(to: target, options: .atomic)
    _ = chmod(target.path, 0o600)
} catch {
    // Status reporting must never block Antigravity.
}

finishAndExit(0)
