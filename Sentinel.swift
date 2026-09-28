import SwiftUI

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

@MainActor final class ActivityStore: ObservableObject {
    @Published var activities: [ActivitySnapshot] = []
    @Published var integrationStatus: [String: String] = [:]
    @Published var usageBySource: [String: AgentUsageSnapshot] = [:]
    private var timer: Timer?
    private let integrations: [any AgentIntegration] = [CodexCLIIntegration()]
    private let usageProviders: [any AgentUsageProvider] = [CodexUsageProvider()]
    private var lastUsageRefresh = Date.distantPast

    init() {
        installIntegrations()
        refresh()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func installIntegrations() {
        for integration in integrations {
            do { integrationStatus[integration.id] = try integration.install() }
            catch { integrationStatus[integration.id] = "Failed to connect \(integration.displayName): " + error.localizedDescription }
        }
    }

    func refresh() {
        let folders = [StateLocation.current, StateLocation.legacy]
        let files = folders.flatMap {
            (try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? []
        }
        let decoder = JSONDecoder()
        let decoded = files.filter { $0.pathExtension == "json" }.compactMap { url -> ActivitySnapshot? in
            guard let bytes = try? Data(contentsOf: url) else { return nil }
            return try? decoder.decode(ActivitySnapshot.self, from: bytes)
        }
        activities = Dictionary(grouping: decoded, by: { $0.sourceID + ":" + $0.id })
            .compactMap { $0.value.max { $0.updatedAt < $1.updatedAt } }
            .sorted { $0.updatedAt > $1.updatedAt }
        if Date().timeIntervalSince(lastUsageRefresh) >= 10 {
            usageBySource = Dictionary(uniqueKeysWithValues: usageProviders.compactMap { provider in
                provider.latestUsage().map { ($0.sourceID, $0) }
            })
            lastUsageRefresh = Date()
        }
    }

    var activitySummary: ActivitySummary { ActivitySummary(activities: activities) }
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
}

struct Counter: View {
    let number: Int
    let name: String
    let symbol: String
    let color: Color
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).foregroundStyle(color).font(.title2)
            VStack(alignment: .leading) {
                Text("\(number)").font(.title2.bold())
                Text(name).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
    }
}

struct UsageCard: View {
    let usage: AgentUsageSnapshot

    private func color(for remaining: Double) -> Color {
        if remaining <= 15 { return .red }
        if remaining <= 35 { return .yellow }
        return .green
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("\(usage.sourceName) usage", systemImage: "gauge.with.dots.needle.50percent")
                    .font(.headline)
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
            ForEach(usage.windows) { window in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(window.name).font(.subheadline.bold())
                        Spacer()
                        Text("\(Int(window.remainingPercent.rounded()))% remaining")
                            .font(.subheadline.monospacedDigit())
                    }
                    ProgressView(value: window.remainingPercent, total: 100)
                        .tint(color(for: window.remainingPercent))
                    Text("Resets \(window.resetsAt, style: .relative)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 14))
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
    private var indicatorLabel: String {
        switch store.signal {
        case .fullAttention: return "Needs attention"
        case .partialAttention: return "Some need attention"
        case .active: return "Running"
        case .idle: return "Idle"
        case .inactive: return "Inactive"
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
                Label(store.summary, systemImage: store.icon)
                    .padding(10).background(.quaternary.opacity(0.5), in: Capsule())
            }
            HStack(spacing: 12) {
                Counter(number: store.count(.needsAttention), name: "Needs attention", symbol: "exclamationmark.circle.fill", color: .yellow)
                Counter(number: store.count(.running), name: "Running", symbol: "bolt.fill", color: .green)
                Counter(number: store.count(.idle), name: "Idle", symbol: "pause.fill", color: .blue)
            }
            ForEach(store.usageBySource.keys.sorted(), id: \.self) { sourceID in
                if let usage = store.usageBySource[sourceID] {
                    UsageCard(usage: usage)
                }
            }
            HStack {
                Text("Agent activity").font(.title3.bold())
                Spacer()
                Button("Refresh") { store.refresh() }
            }
            ScrollView {
                LazyVStack(spacing: 10) {
                    if store.activities.isEmpty {
                        Text("No activity yet. Connect and run an AI agent.")
                            .frame(maxWidth: .infinity, minHeight: 130)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(store.activities) { activity in
                        HStack(spacing: 12) {
                            Image(systemName: activity.symbol).foregroundStyle(activity.tint)
                                .frame(width: 34, height: 34)
                                .background(activity.tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 9))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(activity.project).font(.headline)
                                Text(activity.sourceName + " · " + (activity.workspace.isEmpty ? String(activity.id.prefix(8)) : activity.workspace))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 4) {
                                Text(activity.title).foregroundStyle(activity.tint)
                                Text(activity.updatedAt, style: .relative)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(12)
                        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
                        .help("Source: \(activity.sourceName)\nActivity: \(activity.id)\(activity.detail.map { "\nDetail: \($0)" } ?? "")")
                    }
                }
            }
            Divider()
            HStack(spacing: 14) {
                Image(systemName: "lightbulb.2.fill").font(.title2).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Status indicator").font(.headline)
                    Text("No external device required")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                TimelineView(.periodic(from: .now, by: 0.5)) { context in
                    let visible = ![AttentionSignal.active, .partialAttention].contains(store.signal)
                        || Int(context.date.timeIntervalSince1970 * 2) % 2 == 0
                    Circle().fill(visible ? indicatorColor : .gray.opacity(0.2))
                        .frame(width: 22, height: 22)
                }
                Text(indicatorLabel)
            }
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
        Divider()
        Text(store.summary)
        if let usage = store.usageBySource["codex-cli"] {
            ForEach(usage.windows) { window in
                Text("\(window.name): \(Int(window.remainingPercent.rounded()))% remaining")
            }
        }
        ForEach(store.activities.prefix(8)) { activity in
            Label("\(activity.project) · \(activity.title)", systemImage: activity.symbol)
        }
        Divider()
        Button("Quit") { NSApplication.shared.terminate(nil) }
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
    }
}
