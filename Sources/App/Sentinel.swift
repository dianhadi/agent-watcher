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

@MainActor final class ActivityStore: ObservableObject {
    @Published var activities: [ActivitySnapshot] = []
    @Published var integrationStatus: [String: String] = [:]
    @Published var usageBySource: [String: AgentUsageSnapshot] = [:]
    private var timer: Timer?
    private let integrations: [any AgentIntegration] = [CodexCLIIntegration(), AntigravityIntegration()]
    private let usageProviders: [any AgentUsageProvider] = [CodexUsageProvider(), AntigravityUsageProvider()]
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
        integrations.forEach { $0.maintain() }
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
}

struct UsageCard: View {
    let usage: AgentUsageSnapshot
    @State private var showsAdditionalLimits = false

    private func color(for remaining: Double) -> Color {
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
            Text(activity.sourceName)
                .font(.caption.bold())
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
        .help("Source: \(activity.sourceName)\nActivity: \(activity.id)\(activity.detail.map { "\nDetail: \($0)" } ?? "")")
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
                    let blinks = [AttentionSignal.active, .partialAttention].contains(store.signal)
                    let isLit = !blinks || Int(context.date.timeIntervalSince1970 * 2) % 2 == 0
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
