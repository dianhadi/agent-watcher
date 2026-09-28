import Foundation

/// Best-effort reader for quota metadata exposed by a running Antigravity CLI.
/// Only model labels, remaining fractions, reset times, and the plan name are read.
struct AntigravityUsageProvider: AgentUsageProvider {
    let sourceID = "antigravity"

    func latestUsage() -> AgentUsageSnapshot? {
        for port in listeningPorts() {
            guard let response = requestStatus(port: port),
                  let snapshot = snapshot(from: response) else { continue }
            return snapshot
        }
        return nil
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

    private func requestStatus(port: Int) -> [String: Any]? {
        let service = "exa.language_server_pb.LanguageServerService"
        guard let url = URL(string: "http://127.0.0.1:\(port)/\(service)/GetUserStatus") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 2)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
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
