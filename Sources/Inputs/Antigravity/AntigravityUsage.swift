import Foundation
import Darwin

private struct AntigravityConnection {
    let address: String
    let csrfToken: String
}

/// Best-effort reader for quota metadata exposed by a running Antigravity CLI.
/// Only model labels, remaining fractions, reset times, and the plan name are read.
final class AntigravityUsageProvider: AgentUsageProvider {
    let sourceID = "antigravity"
    private static var socketPath: String { "/tmp/agent-watcher-antigravity-\(getuid()).sock" }
    private var connection: AntigravityConnection?
    private var statusLineUsage: AgentUsageSnapshot?
    private var serverSocket: Int32 = -1
    private var socketSource: DispatchSourceRead?

    init() {
        startConnectionListener()
    }

    deinit {
        socketSource?.cancel()
        if serverSocket >= 0 { close(serverSocket) }
        unlink(Self.socketPath)
    }

    private func startConnectionListener() {
        unlink(Self.socketPath)
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        guard setSocketPath(Self.socketPath, on: &address) else {
            close(descriptor)
            return
        }
        let length = socklen_t(MemoryLayout<sa_family_t>.size + Self.socketPath.utf8.count + 1)
        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, length)
            }
        }
        guard bindResult == 0, listen(descriptor, 4) == 0 else {
            close(descriptor)
            unlink(Self.socketPath)
            return
        }
        _ = chmod(Self.socketPath, 0o600)
        _ = fcntl(descriptor, F_SETFL, O_NONBLOCK)
        serverSocket = descriptor
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: .global(qos: .utility))
        source.setEventHandler { [weak self] in self?.acceptConnections() }
        socketSource = source
        source.resume()
    }

    private func setSocketPath(_ path: String, on address: inout sockaddr_un) -> Bool {
        let bytes = Array(path.utf8CString)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        return withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) {
                guard bytes.count <= capacity else { return false }
                for index in bytes.indices { $0[index] = bytes[index] }
                return true
            }
        }
    }

    private func acceptConnections() {
        while true {
            let client = accept(serverSocket, nil, nil)
            guard client >= 0 else { return }
            var bytes = [UInt8](repeating: 0, count: 16 * 1024)
            let count = recv(client, &bytes, bytes.count, 0)
            close(client)
            guard count > 0 else { continue }
            let data = Data(bytes.prefix(Int(count)))
            DispatchQueue.main.async { [weak self] in self?.receiveConnection(data) }
        }
    }

    private func receiveConnection(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { return }
        if type == "usage", let snapshot = statusLineSnapshot(from: object) {
            statusLineUsage = snapshot
            return
        }
        guard type == "connection",
              let address = object["address"] as? String,
              let token = object["csrf_token"] as? String,
              !token.isEmpty,
              isLoopbackAddress(address) else { return }
        connection = AntigravityConnection(address: address, csrfToken: token)
    }

    func latestUsage() -> AgentUsageSnapshot? {
        if let statusLineUsage,
           Date().timeIntervalSince(statusLineUsage.updatedAt) < 15 * 60 {
            return statusLineUsage
        }
        if let connection,
           let response = requestStatus(address: connection.address, csrfToken: connection.csrfToken),
           let snapshot = snapshot(from: response) {
            return snapshot
        }
        for port in listeningPorts() {
            guard let response = requestStatus(address: "127.0.0.1:\(port)", csrfToken: nil),
                  let snapshot = snapshot(from: response) else { continue }
            return snapshot
        }
        return nil
    }

    private func statusLineSnapshot(from object: [String: Any]) -> AgentUsageSnapshot? {
        guard let quotas = object["quota"] as? [String: Any] else { return nil }
        let formatter = ISO8601DateFormatter()
        let windows = quotas.compactMap { key, value -> UsageWindow? in
            guard let quota = value as? [String: Any],
                  let remaining = number(quota["remaining_fraction"]),
                  let resetText = quota["reset_time"] as? String,
                  let reset = formatter.date(from: resetText) else { return nil }
            let lower = key.lowercased()
            let duration = lower.contains("weekly") ? 10_080 : 300
            let name = key.split(separator: "-")
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")
            return UsageWindow(
                id: key,
                name: name,
                usedPercent: (1 - min(1, max(0, remaining))) * 100,
                durationMinutes: duration,
                resetsAt: reset
            )
        }.sorted { $0.name < $1.name }
        guard !windows.isEmpty else { return nil }
        return AgentUsageSnapshot(
            sourceID: sourceID,
            sourceName: "Antigravity",
            planName: object["plan_name"] as? String,
            windows: windows,
            updatedAt: Date()
        )
    }

    private func listeningPorts() -> [Int] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        task.arguments = ["-nP", "-iTCP", "-sTCP:LISTEN", "-a", "-c", "agy"]
        let output = Pipe()
        task.standardOutput = output
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return [] }
        task.waitUntilExit()
        guard let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) else {
            return []
        }
        var seen = Set<Int>()
        return text.split(separator: "\n").compactMap { line in
            guard line.contains("(LISTEN)"),
                  let token = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                    .first(where: { $0.contains(":") && !$0.contains("->") }),
                  let port = Int(token.split(separator: ":").last ?? "") else { return nil }
            return seen.insert(port).inserted ? port : nil
        }
    }

    private func requestStatus(address: String, csrfToken: String?) -> [String: Any]? {
        let service = "exa.language_server_pb.LanguageServerService"
        guard isLoopbackAddress(address),
              let url = URL(string: "http://\(address)/\(service)/GetUserStatus") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 2)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        if let csrfToken {
            request.setValue(csrfToken, forHTTPHeaderField: "x-codeium-csrf-token")
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "metadata": [
                "ideName": "antigravity", "extensionName": "antigravity",
                "ideVersion": "unknown", "locale": "en"
            ]
        ])

        let semaphore = DispatchSemaphore(value: 0)
        var result: [String: Any]?
        URLSession.shared.dataTask(with: request) { data, response, _ in
            defer { semaphore.signal() }
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode), let data,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            result = object
        }.resume()
        _ = semaphore.wait(timeout: .now() + 2.5)
        return result
    }

    private func isLoopbackAddress(_ address: String) -> Bool {
        guard let separator = address.lastIndex(of: ":"),
              let port = Int(address[address.index(after: separator)...]),
              (1...65_535).contains(port) else { return false }
        let host = String(address[..<separator]).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }

    private func snapshot(from root: [String: Any]) -> AgentUsageSnapshot? {
        guard let status = root["userStatus"] as? [String: Any],
              let modelData = status["cascadeModelConfigData"] as? [String: Any],
              let configs = modelData["clientModelConfigs"] as? [[String: Any]] else { return nil }

        var pools: [String: UsageWindow] = [:]
        for config in configs {
            guard let rawLabel = config["label"] as? String,
                  let quota = config["quotaInfo"] as? [String: Any],
                  let remaining = number(quota["remainingFraction"]),
                  let resetText = quota["resetTime"] as? String,
                  let reset = ISO8601DateFormatter().date(from: resetText) else { continue }
            let label = poolName(for: rawLabel)
            let window = UsageWindow(
                id: label.lowercased().replacingOccurrences(of: " ", with: "-"),
                name: label,
                usedPercent: (1 - min(1, max(0, remaining))) * 100,
                durationMinutes: 300,
                resetsAt: reset
            )
            if pools[label].map({ $0.usedPercent < window.usedPercent }) ?? true {
                pools[label] = window
            }
        }
        let windows = pools.values.sorted { $0.name < $1.name }
        guard !windows.isEmpty else { return nil }
        let tier = status["userTier"] as? [String: Any]
        let planStatus = status["planStatus"] as? [String: Any]
        let planInfo = planStatus?["planInfo"] as? [String: Any]
        return AgentUsageSnapshot(
            sourceID: sourceID,
            sourceName: "Antigravity",
            planName: tier?["name"] as? String ?? planInfo?["planName"] as? String,
            windows: windows,
            updatedAt: Date()
        )
    }

    private func poolName(for label: String) -> String {
        let lower = label.lowercased()
        if lower.contains("gemini") && lower.contains("pro") { return "Gemini Pro" }
        if lower.contains("gemini") && lower.contains("flash") { return "Gemini Flash" }
        return "Claude"
    }

    private func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }
}
