import Foundation
import Darwin

var stdoutResponse = "{}"

func sendUsageMessage(_ object: [String: Any]) {
    guard let bytes = try? JSONSerialization.data(withJSONObject: object) else { return }
    let path = "/tmp/agent-watcher-antigravity-\(getuid()).sock"
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { return }
    defer { close(descriptor) }
    var socketAddress = sockaddr_un()
    socketAddress.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(path.utf8CString)
    let pathCapacity = MemoryLayout.size(ofValue: socketAddress.sun_path)
    let pathFits = withUnsafeMutablePointer(to: &socketAddress.sun_path) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: pathCapacity) {
            guard pathBytes.count <= pathCapacity else { return false }
            for index in pathBytes.indices { $0[index] = pathBytes[index] }
            return true
        }
    }
    guard pathFits else { return }
    let length = socklen_t(MemoryLayout<sa_family_t>.size + path.utf8.count + 1)
    let connected = withUnsafePointer(to: &socketAddress) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(descriptor, $0, length)
        }
    }
    guard connected == 0 else { return }
    bytes.withUnsafeBytes { buffer in
        guard let base = buffer.baseAddress else { return }
        _ = send(descriptor, base, buffer.count, 0)
    }
}

func publishUsageConnection() {
    let environment = ProcessInfo.processInfo.environment
    guard let address = environment["ANTIGRAVITY_LS_ADDRESS"], !address.isEmpty,
          let token = environment["ANTIGRAVITY_CSRF_TOKEN"], !token.isEmpty else { return }
    sendUsageMessage([
        "type": "connection",
        "address": address,
        "csrf_token": token
    ])
}

func writeActivitySnapshot(id: String, workspace: String, state: String, detail: String? = nil) {
    let safeID = String(id.unicodeScalars.filter {
        CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
    })
    guard !safeID.isEmpty else { return }
    do {
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
        if let detail { snapshot["detail"] = detail }
        let bytes = try JSONSerialization.data(withJSONObject: snapshot)
        let target = folder.appendingPathComponent(safeID + ".json")
        try bytes.write(to: target, options: .atomic)
        _ = chmod(target.path, 0o600)
    } catch {
        // Status reporting must never block Antigravity.
    }
}

func publishStatusLineActivity(_ payload: [String: Any]) {
    guard let id = payload["conversation_id"] as? String
            ?? payload["session_id"] as? String,
          !id.isEmpty else { return }
    let workspaceInfo = payload["workspace"] as? [String: Any]
    let workspace = workspaceInfo?["project_dir"] as? String
        ?? workspaceInfo?["current_dir"] as? String
        ?? payload["cwd"] as? String
        ?? ""
    let needsAttention = payload["tool_confirmation_pending"] as? Bool ?? false
    if needsAttention {
        writeActivitySnapshot(id: id, workspace: workspace, state: "needs_attention", detail: "tool approval")
        return
    }
    switch payload["agent_state"] as? String {
    case "idle":
        writeActivitySnapshot(id: id, workspace: workspace, state: "idle")
    case "thinking", "working", "tool_use", "initializing":
        writeActivitySnapshot(id: id, workspace: workspace, state: "running")
    default:
        break
    }
}

func publishStatusLineUsage() -> Never {
    stdoutResponse = ""
    let input = FileHandle.standardInput.readDataToEndOfFile()
    guard let payload = try? JSONSerialization.jsonObject(with: input) as? [String: Any] else {
        finishAndExit(0)
    }
    publishStatusLineActivity(payload)
    guard let quota = payload["quota"] as? [String: Any], !quota.isEmpty else { finishAndExit(0) }
    var message: [String: Any] = ["type": "usage", "quota": quota]
    if let plan = payload["plan_tier"] as? String { message["plan_name"] = plan }
    if let model = payload["model"] as? [String: Any] {
        if let name = model["display_name"] as? String ?? model["id"] as? String {
            message["model_name"] = name
        }
    }
    sendUsageMessage(message)
    finishAndExit(0)
}

func finishAndExit(_ code: Int32 = 0) -> Never {
    if let data = (stdoutResponse + "\n").data(using: .utf8) {
        FileHandle.standardOutput.write(data)
    }
    exit(code)
}

do {
    if CommandLine.arguments.dropFirst().first == "StatusLine" {
        publishStatusLineUsage()
    }
    publishUsageConnection()
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
    case "SessionEnd":
        state = "ended"
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

    writeActivitySnapshot(id: id, workspace: workspace, state: state, detail: detail)
} catch {
    // Status reporting must never block Antigravity.
}

finishAndExit(0)
