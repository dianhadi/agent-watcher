import SwiftUI
import CoreServices

extension ActivitySnapshot {
    var title: String {
        switch ActivitySummary(activities: []).currentState(of: self) {
        case .needsAttention: return "Needs attention"
        case .running: return "Running"
        case .idle: return "Idle"
        case .ended: return "Activity ended"
        default: return "Status unknown"
        }
    }
    var symbol: String {
        switch ActivitySummary(activities: []).currentState(of: self) {
        case .needsAttention: return "exclamationmark.circle.fill"
        case .running: return "bolt.fill"
        case .idle: return "pause.fill"
        case .ended: return "checkmark.circle.fill"
        default: return "questionmark.circle"
        }
    }
    var tint: Color {
        switch ActivitySummary(activities: []).currentState(of: self) {
        case .needsAttention: return .yellow
        case .running: return .green
        case .idle: return .blue
        default: return .gray
        }
    }
}

private enum OutputSuspensionReason: Hashable {
    case terminating
    case sessionInactive
    case screenLocked
}

@MainActor final class ActivityStore: ObservableObject {
    @Published var activities: [ActivitySnapshot] = []
    @Published var integrationStatus: [String: String] = [:]
    @Published var usageBySource: [String: AgentUsageSnapshot] = [:]
    @Published private(set) var outputDeviceStatuses: [OutputDeviceStatus] = []
    @Published private(set) var enabledIntegrationIDs: Set<String> = []
    @Published private(set) var enabledOutputIDs: Set<String> = []
    @Published private(set) var outputErrors: [String: String] = [:]
    private var timer: Timer?
    private var outputTimer: Timer?
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var outputSuspensionReasons: Set<OutputSuspensionReason> = []
    private let integrations: [any AgentIntegration] = [CodexCLIIntegration(), AntigravityIntegration()]
    private let outputs: [any ActivityOutput]
    private let outputDeviceDetectors: [any OutputDeviceDetector]
    private var usageProviders: [String: any AgentUsageProvider] = [:]
    private var lastUsageRefresh = Date.distantPast
    private let defaults = UserDefaults.standard

    init() {
        let luxafor = LuxaforOutput()
        outputs = [luxafor]
        outputDeviceDetectors = [luxafor]
        prepareLocalInputMonitoringIdentity()
        let codexKey = preferenceKey(for: "codex-cli")
        let codexEnabled = defaults.object(forKey: codexKey) as? Bool ?? true
        if codexEnabled { enabledIntegrationIDs.insert("codex-cli") }
        for output in outputs {
            if defaults.object(forKey: outputPreferenceKey(for: output.id)) as? Bool ?? false {
                enabledOutputIDs.insert(output.id)
            }
        }
        // Antigravity is intentionally unavailable until its adapter is ready
        // to be enabled from Settings.
        defaults.set(false, forKey: preferenceKey(for: "antigravity"))
        synchronizeUsageProviders()
        installIntegrations()
        refresh()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        let outputTimer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.publishOutputs() }
        }
        self.outputTimer = outputTimer
        RunLoop.main.add(outputTimer, forMode: .common)
        lifecycleObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.suspendOutputs(for: .terminating)
            }
        })
        let workspaceNotifications = NSWorkspace.shared.notificationCenter
        lifecycleObservers.append(workspaceNotifications.addObserver(
            forName: NSWorkspace.sessionDidResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.suspendOutputs(for: .sessionInactive)
            }
        })
        lifecycleObservers.append(workspaceNotifications.addObserver(
            forName: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.resumeOutputs(for: .sessionInactive)
            }
        })
        let distributedNotifications = DistributedNotificationCenter.default()
        lifecycleObservers.append(distributedNotifications.addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.suspendOutputs(for: .screenLocked)
            }
        })
        lifecycleObservers.append(distributedNotifications.addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.resumeOutputs(for: .screenLocked)
            }
        })
    }

    func installIntegrations() {
        for integration in integrations {
            do {
                if isIntegrationEnabled(integration.id) {
                    integrationStatus[integration.id] = try integration.install()
                } else {
                    integrationStatus[integration.id] = try integration.uninstall()
                    removeSnapshots(sourceID: integration.id)
                }
            }
            catch { integrationStatus[integration.id] = "Failed to connect \(integration.displayName): " + error.localizedDescription }
        }
        refresh()
    }

    func isIntegrationEnabled(_ id: String) -> Bool {
        enabledIntegrationIDs.contains(id)
    }

    func setIntegrationEnabled(_ enabled: Bool, id: String) {
        guard id != "antigravity" else { return }
        defaults.set(enabled, forKey: preferenceKey(for: id))
        if enabled { enabledIntegrationIDs.insert(id) }
        else { enabledIntegrationIDs.remove(id) }
        synchronizeUsageProviders()
        guard let integration = integrations.first(where: { $0.id == id }) else { return }
        do {
            if enabled { integrationStatus[id] = try integration.install() }
            else { integrationStatus[id] = try integration.uninstall() }
            if !enabled { removeSnapshots(sourceID: id) }
        } catch {
            integrationStatus[id] = "Failed to update \(integration.displayName): " + error.localizedDescription
        }
        lastUsageRefresh = .distantPast
        refresh()
    }

    func isOutputEnabled(_ id: String) -> Bool {
        enabledOutputIDs.contains(id)
    }

    func setOutputEnabled(_ enabled: Bool, id: String) {
        guard let output = outputs.first(where: { $0.id == id }) else { return }
        defaults.set(enabled, forKey: outputPreferenceKey(for: id))
        if enabled {
            enabledOutputIDs.insert(id)
            requestOutputAccess(id)
        } else {
            try? output.publish(.inactive)
            enabledOutputIDs.remove(id)
            outputErrors.removeValue(forKey: id)
        }
        refresh()
    }

    func requestOutputAccess(_ id: String) {
        guard let detector = outputDeviceDetectors.first(where: { $0.id == id }) else { return }
        // pkgbuild installs do not always appear in the Launch Services database
        // immediately. TCC needs this registration before it can list the app in
        // Privacy & Security > Input Monitoring.
        _ = LSRegisterURL(Bundle.main.bundleURL as CFURL, true)
        if !detector.requestAccess(),
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
        refresh()
    }

    func refresh() {
        integrations.filter { isIntegrationEnabled($0.id) }.forEach { $0.maintain() }
        outputDeviceStatuses = outputDeviceDetectors.map { $0.currentStatus() }
        let folders = [StateLocation.current, StateLocation.legacy]
        let files = folders.flatMap {
            (try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? []
        }
        let decoder = JSONDecoder()
        let decoded = files.filter { $0.pathExtension == "json" }.compactMap { url -> ActivitySnapshot? in
            guard let bytes = try? Data(contentsOf: url) else { return nil }
            guard let snapshot = try? decoder.decode(ActivitySnapshot.self, from: bytes),
                  isIntegrationEnabled(snapshot.sourceID) else { return nil }
            return snapshot
        }
        activities = Dictionary(grouping: decoded, by: { $0.sourceID + ":" + $0.id })
            .compactMap { $0.value.max { $0.updatedAt < $1.updatedAt } }
            .sorted { $0.updatedAt > $1.updatedAt }
        if Date().timeIntervalSince(lastUsageRefresh) >= 10 {
            usageBySource = Dictionary(uniqueKeysWithValues: usageProviders.values.compactMap { provider in
                provider.latestUsage().map { ($0.sourceID, $0) }
            })
            lastUsageRefresh = Date()
        }
        publishOutputs()
    }

    var activitySummary: ActivitySummary { ActivitySummary(activities: activities) }
    var visibleActivities: [ActivitySnapshot] {
        activities.filter { activity in
            if activity.state == .ended {
                return Date().timeIntervalSince(activity.updatedAt) < 10 * 60
            }
            return activitySummary.currentState(of: activity) != .unknown
        }
    }
    func count(_ state: ActivityState) -> Int { activitySummary.count(state) }
    var signal: AttentionSignal { activitySummary.signal }
    var summary: String {
        switch signal {
        case .fullAttention: return "All activities need attention"
        case .partialAttention: return "Some activities need attention"
        case .active: return "An activity is running"
        case .inactive: return "No active activities"
        case .idle: return "All activities are idle"
        }
    }
    var icon: String {
        switch signal {
        case .fullAttention, .partialAttention: return "exclamationmark.circle.fill"
        case .active: return "bolt.circle.fill"
        case .inactive: return "circle"
        case .idle: return "pause.circle"
        }
    }

    private func preferenceKey(for id: String) -> String {
        "integration.\(id).enabled"
    }

    private func outputPreferenceKey(for id: String) -> String {
        "output.\(id).enabled"
    }

    private func prepareLocalInputMonitoringIdentity() {
        guard let buildIdentity = Bundle.main.object(
            forInfoDictionaryKey: "AgentWatcherLocalBuildIdentity"
        ) as? String else { return }
        let defaultsKey = "input-monitoring.local-build-identity"
        guard defaults.string(forKey: defaultsKey) != buildIdentity else { return }

        _ = LSRegisterURL(Bundle.main.bundleURL as CFURL, true)
        let reset = Process()
        reset.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        reset.arguments = ["reset", "ListenEvent", "io.github.agent-watcher"]
        do {
            try reset.run()
            reset.waitUntilExit()
            if reset.terminationStatus == 0 {
                defaults.set(buildIdentity, forKey: defaultsKey)
            }
        } catch {
            // A failed permission reset must never prevent the app from opening.
        }
    }

    private func publishOutputs() {
        guard outputSuspensionReasons.isEmpty else { return }
        for output in outputs where isOutputEnabled(output.id) {
            do {
                try output.publish(signal)
                if outputErrors[output.id] != nil {
                    outputErrors.removeValue(forKey: output.id)
                }
            } catch {
                if outputErrors[output.id] != error.localizedDescription {
                    outputErrors[output.id] = error.localizedDescription
                }
            }
        }
    }

    private func turnOffOutputs() {
        for output in outputs where isOutputEnabled(output.id) {
            try? output.publish(.inactive)
        }
    }

    private func suspendOutputs(for reason: OutputSuspensionReason) {
        outputSuspensionReasons.insert(reason)
        turnOffOutputs()
    }

    private func resumeOutputs(for reason: OutputSuspensionReason) {
        outputSuspensionReasons.remove(reason)
        publishOutputs()
    }

    private func synchronizeUsageProviders() {
        if isIntegrationEnabled("codex-cli") {
            if usageProviders["codex-cli"] == nil { usageProviders["codex-cli"] = CodexUsageProvider() }
        } else {
            usageProviders.removeValue(forKey: "codex-cli")
            usageBySource.removeValue(forKey: "codex-cli")
        }
        if isIntegrationEnabled("antigravity") {
            if usageProviders["antigravity"] == nil { usageProviders["antigravity"] = AntigravityUsageProvider() }
        } else {
            usageProviders.removeValue(forKey: "antigravity")
            usageBySource.removeValue(forKey: "antigravity")
        }
    }

    private func removeSnapshots(sourceID: String) {
        let decoder = JSONDecoder()
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: StateLocation.current,
            includingPropertiesForKeys: nil
        ) else { return }
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let snapshot = try? decoder.decode(ActivitySnapshot.self, from: data),
                  snapshot.sourceID == sourceID else { continue }
            try? FileManager.default.removeItem(at: file)
        }
        activities.removeAll { $0.sourceID == sourceID }
        usageBySource.removeValue(forKey: sourceID)
    }
}

struct UsageCard: View {
    let usage: AgentUsageSnapshot
    @State private var showsAdditionalLimits = false

    private func color(for remaining: Double) -> Color {
        if remaining >= 99.5 { return .blue }
        if remaining < 20 { return .red }
        if remaining < 50 { return .yellow }
        return .green
    }

    private func progressBar(for window: UsageWindow) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.gray.opacity(0.2))
                Capsule()
                    .fill(color(for: window.remainingPercent))
                    .frame(width: geometry.size.width * window.remainingPercent / 100)
            }
        }
        .frame(height: 6)
        .accessibilityLabel("\(window.name) quota")
        .accessibilityValue("\(Int(window.remainingPercent.rounded())) percent remaining")
    }

    private var primary: UsageWindow? {
        usage.windows.first { $0.durationMinutes == 300 } ?? usage.windows.first
    }

    private var additional: [UsageWindow] {
        guard let primary else { return usage.windows }
        return usage.windows.filter { $0.id != primary.id }
    }

    private func limitRow(_ window: UsageWindow, showsName: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                if showsName { Text(window.name).font(.subheadline.bold()) }
                Text("\(Int(window.remainingPercent.rounded()))% remaining")
                    .font(.subheadline.monospacedDigit())
                Spacer()
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(resetLabel(for: window, now: context.date))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            progressBar(for: window)
        }
    }

    private func resetLabel(for window: UsageWindow, now: Date) -> String {
        let seconds = max(0, Int(window.resetsAt.timeIntervalSince(now)))
        if seconds == 0 { return "Reset due" }
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if days > 0 { return "Resets in \(days)d \(hours)h" }
        if hours > 0 { return "Resets in \(hours)h \(minutes)m" }
        return "Resets in \(max(1, minutes))m"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("\(usage.sourceName) · 5-hour limit", systemImage: "gauge.with.dots.needle.50percent")
                    .font(.subheadline.bold())
                Spacer()
                if let plan = usage.planName, !plan.isEmpty {
                    Text(plan.capitalized)
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.quaternary.opacity(0.6), in: Capsule())
                }
            }
            if let primary {
                limitRow(primary, showsName: false)
            }
            if !additional.isEmpty {
                DisclosureGroup("Additional limits", isExpanded: $showsAdditionalLimits) {
                    VStack(spacing: 8) {
                        ForEach(additional) { window in
                            limitRow(window, showsName: true)
                        }
                    }
                    .padding(.top, 6)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 14))
    }
}

struct ActivityCard: View {
    let activity: ActivitySnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: activity.symbol)
                    .foregroundStyle(activity.tint)
                Text(activity.project)
                    .font(.headline)
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
            HStack(spacing: 5) {
                Text(activity.sourceName)
                    .font(.caption.bold())
                if let modelName = activity.modelName, !modelName.isEmpty {
                    Text("·")
                    Text(modelName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if !activity.workspace.isEmpty {
                Text(activity.workspace)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            HStack {
                Text(String(activity.id.prefix(8)))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                Spacer()
                Text(activity.updatedAt, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(.quaternary, lineWidth: 1)
        }
        .help("Source: \(activity.sourceName)\(activity.modelName.map { "\nModel: \($0)" } ?? "")\nActivity: \(activity.id)\(activity.detail.map { "\nDetail: \($0)" } ?? "")")
    }
}

struct ActivityColumn: View {
    let title: String
    let subtitle: String
    let symbol: String
    let color: Color
    let activities: [ActivitySnapshot]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: symbol).foregroundStyle(color)
                Text(title).font(.headline)
                Spacer()
                Text("\(activities.count)")
                    .font(.caption.bold())
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
            }
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(spacing: 8) {
                    if activities.isEmpty {
                        Text("No activities")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, minHeight: 70)
                    }
                    ForEach(activities) { activity in
                        ActivityCard(activity: activity)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 14))
    }
}

struct Dashboard: View {
    @ObservedObject var store: ActivityStore
    private var indicatorColor: Color {
        switch store.signal {
        case .fullAttention: return .red
        case .partialAttention: return .yellow
        case .active: return .green
        case .idle: return .blue
        case .inactive: return .gray.opacity(0.25)
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                VStack(alignment: .leading) {
                    Text("Agent Watcher").font(.largeTitle.bold())
                    Text("AI agent activity on this Mac").foregroundStyle(.secondary)
                }
                Spacer()
                TimelineView(.periodic(from: .now, by: 0.5)) { context in
                    let isLit = store.signal.isLit(at: context.date)
                    HStack(spacing: 7) {
                        Image(systemName: store.icon)
                            .font(.system(size: 36, weight: .semibold))
                            .frame(width: 44, height: 44)
                            .foregroundStyle(isLit ? indicatorColor : .gray.opacity(0.2))
                        Text(store.summary)
                            .font(.body)
                    }
                    .padding(10)
                    .background(.quaternary.opacity(0.5), in: Capsule())
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(store.summary)
                }
            }
            Text("Agent board").font(.title3.bold())
            GeometryReader { geometry in
                let columnWidth = max(0, (geometry.size.width - 36) / 4)
                HStack(alignment: .top, spacing: 12) {
                    ActivityColumn(
                        title: "Idle", subtitle: "Waiting for work", symbol: "pause.fill", color: .blue,
                        activities: store.visibleActivities.filter { store.activitySummary.currentState(of: $0) == .idle }
                    )
                    .frame(width: columnWidth)
                    ActivityColumn(
                        title: "Needs Attention", subtitle: "Waiting for input", symbol: "exclamationmark.circle.fill", color: .yellow,
                        activities: store.visibleActivities.filter { store.activitySummary.currentState(of: $0) == .needsAttention }
                    )
                    .frame(width: columnWidth)
                    ActivityColumn(
                        title: "Running", subtitle: "Work in progress", symbol: "bolt.fill", color: .green,
                        activities: store.visibleActivities.filter { store.activitySummary.currentState(of: $0) == .running }
                    )
                    .frame(width: columnWidth)
                    ActivityColumn(
                        title: "Ended", subtitle: "Visible for 10 minutes", symbol: "checkmark.circle.fill", color: .gray,
                        activities: store.visibleActivities.filter { $0.state == .ended }
                    )
                    .frame(width: columnWidth)
                }
            }
            .frame(minHeight: 230)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 290, maximum: 340), spacing: 12)], alignment: .leading, spacing: 12) {
                ForEach(store.usageBySource.keys.sorted(), id: \.self) { sourceID in
                    if let usage = store.usageBySource[sourceID] {
                        UsageCard(usage: usage)
                            .frame(width: 320, alignment: .topLeading)
                    }
                }
            }
            Divider()
            HStack(spacing: 8) {
                Image(systemName: "link")
                Text(store.integrationStatus.values.sorted().joined(separator: " · ")).font(.caption)
                Spacer()
                Button("Retry") { store.installIntegrations() }
            }
            .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(minWidth: 690, minHeight: 540)
    }

}

struct MenuContents: View {
    @ObservedObject var store: ActivityStore
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Open dashboard") {
            openWindow(id: "dashboard")
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        Button("Settings…") {
            if !NSApplication.shared.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
                _ = NSApplication.shared.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
            }
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        Divider()
        Text(store.summary)
        ForEach(store.usageBySource.keys.sorted(), id: \.self) { sourceID in
            if let usage = store.usageBySource[sourceID] {
                ForEach(usage.windows) { window in
                    Text("\(window.name): \(Int(window.remainingPercent.rounded()))% remaining")
                }
            }
        }
        ForEach(store.visibleActivities.prefix(8)) { activity in
            Label("\(activity.project) · \(activity.title)", systemImage: activity.symbol)
        }
        Divider()
        Button("Quit") { NSApplication.shared.terminate(nil) }
    }
}

struct AgentWatcherSettings: View {
    @ObservedObject var store: ActivityStore

    private var codexBinding: Binding<Bool> {
        Binding(
            get: { store.isIntegrationEnabled("codex-cli") },
            set: { store.setIntegrationEnabled($0, id: "codex-cli") }
        )
    }

    var body: some View {
        Form {
            Section("Agents") {
                Toggle(isOn: codexBinding) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Codex CLI")
                        Text("Monitor activity and account usage")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
                Toggle(isOn: .constant(false)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Antigravity")
                        Text("Temporarily unavailable")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
                .disabled(true)
            }
            Section("Outputs") {
                ForEach(store.outputDeviceStatuses) { output in
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle(isOn: Binding(
                            get: { store.isOutputEnabled(output.id) },
                            set: { store.setOutputEnabled($0, id: output.id) }
                        )) {
                            HStack(spacing: 10) {
                                Image(systemName: "circle.fill")
                                    .font(.system(size: 9))
                                    .foregroundStyle(
                                        output.isReady ? Color.green
                                            : output.isConnected ? Color.orange : Color.secondary
                                    )
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(output.displayName)
                                    Text(store.outputErrors[output.id] ?? output.detail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .toggleStyle(.checkbox)
                        if output.isConnected && !output.isReady {
                            Button("Grant Input Monitoring Access…") {
                                store.requestOutputAccess(output.id)
                            }
                            .font(.caption)
                            .padding(.leading, 20)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .formStyle(.grouped)
        .padding(12)
        .frame(width: 430, height: 290)
    }
}

@main struct AgentWatcherApp: App {
    @StateObject private var store = ActivityStore()
    var body: some Scene {
        Window("Agent Watcher", id: "dashboard") {
            Dashboard(store: store)
        }
        .defaultSize(width: 780, height: 620)
        MenuBarExtra("Agent Watcher", systemImage: store.icon) {
            MenuContents(store: store)
        }
        Settings {
            AgentWatcherSettings(store: store)
        }
    }
}
