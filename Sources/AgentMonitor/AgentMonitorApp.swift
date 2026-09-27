import AppKit
import Charts
import Darwin
import MonitorCore
import SwiftUI

@main
struct AgentMonitorApp: App {
    @StateObject private var model = MonitorModel()
    private static var lockFD: Int32 = -1

    private enum InstanceLockResult {
        case acquired
        case alreadyRunning
        case failed(String)
    }

    init() {
        if CommandLine.arguments.contains("--snapshot") {
            let sampler = ProcessSampler()
            _ = sampler.sample()
            Thread.sleep(forTimeInterval: 0.55)
            let sample = sampler.sample()
            var harnesses: [String: [String: Any]] = [:]
            for harness in Harness.allCases {
                let usage = sample.usage[harness] ?? ResourceUsage()
                harnesses[harness.rawValue] = [
                    "cpuPercent": usage.cpuPercent,
                    "ramBytes": usage.footprintBytes,
                    "diskWriteBytesPerSecond": usage.diskWriteBytesPerSecond,
                    "processCount": usage.processCount,
                ]
            }
            let data = try! JSONSerialization.data(withJSONObject: [
                "timestamp": ISO8601DateFormatter().string(from: sample.timestamp),
                "active": sample.active,
                "unreadableAgentProcesses": sample.unreadableAgentProcesses,
                "scanFailed": sample.scanFailed,
                "harnesses": harnesses,
            ], options: [.prettyPrinted, .sortedKeys])
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([10]))
            exit(0)
        }
        switch Self.acquireInstanceLock() {
        case .acquired:
            break
        case .alreadyRunning:
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.lazar.agentmonitor")
                .first { $0.processIdentifier != getpid() }?
                .activate(options: [])
            exit(0)
        case .failed(let reason):
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Agent Monitor couldn't start"
            alert.informativeText = "It couldn't open its single-instance lock. \(reason)"
            alert.runModal()
            exit(1)
        }
    }

    private static func acquireInstanceLock() -> InstanceLockResult {
        let directory = HistoryStore.defaultURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return .failed(error.localizedDescription)
        }
        let fd = Darwin.open(directory.appendingPathComponent("instance.lock").path,
                             O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return .failed(String(cString: strerror(errno))) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let lockError = errno
            Darwin.close(fd)
            return lockError == EWOULDBLOCK ? .alreadyRunning : .failed(String(cString: strerror(lockError)))
        }
        lockFD = fd
        return .acquired
    }

    var body: some Scene {
        Window("Agent Monitor", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 740, minHeight: 600)
        }
        .windowStyle(.titleBar)

        MenuBarExtra {
            MenuBarContents(model: model)
        } label: {
            Label("Agent Monitor", systemImage: "memorychip")
        }
        .menuBarExtraStyle(.menu)
    }
}

@MainActor
final class MonitorModel: ObservableObject {
    @Published var live: LiveSample?
    @Published var recent: [LiveSample] = []
    @Published var history: [MinuteRecord] = []
    @Published var error: String?
    @Published var historyError: String?
    @Published var scanFailed = false
    @Published var selectedDays = 7
    @Published var selectedHarness: Harness = .all

    private let collector = Collector()
    private var recentSamples: [LiveSample] = []
    private var lastPublished = Date.distantPast

    init() {
        collector.onSample = { [weak self] sample in
            DispatchQueue.main.async {
                guard let self else { return }
                if sample.scanFailed {
                    if !self.scanFailed { self.scanFailed = true }
                    return
                }
                let recoveredFromFailedScan = self.scanFailed
                if recoveredFromFailedScan { self.scanFailed = false }
                self.recentSamples.append(sample)
                self.recentSamples.removeAll { $0.timestamp < sample.timestamp.addingTimeInterval(-60) }
                if self.recentSamples.count > 120 {
                    self.recentSamples.removeFirst(self.recentSamples.count - 120)
                }
                let windowVisible = NSApp.windows.contains { $0.title == "Agent Monitor" && $0.isVisible }
                if windowVisible || recoveredFromFailedScan {
                    self.live = sample
                    self.recent = self.recentSamples
                    self.lastPublished = sample.timestamp
                } else if sample.timestamp.timeIntervalSince(self.lastPublished) >= 5 {
                    self.live = sample
                    self.lastPublished = sample.timestamp
                }
            }
        }
        collector.onError = { [weak self] message in
            DispatchQueue.main.async { self?.error = message }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.collector.stop() }
        }
        collector.start()
    }

    func reloadHistory() {
        do {
            let store = try HistoryStore()
            history = try store.records(since: Date().addingTimeInterval(-Double(selectedDays) * 86_400),
                                        harness: selectedHarness)
            historyError = nil
        } catch {
            historyError = "History cannot be read: \(error)"
        }
    }
}

struct ContentView: View {
    @ObservedObject var model: MonitorModel
    @State private var tab = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "memorychip.fill")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.teal)
                    .frame(width: 38, height: 38)
                    .background(.teal.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Agent Monitor").font(.system(size: 19, weight: .semibold, design: .rounded))
                    Text("Local resource use for coding agents")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if model.scanFailed {
                    Label("Scan unavailable", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if let live = model.live {
                    HStack(spacing: 6) {
                        Circle().fill(live.active ? .green : .orange).frame(width: 7, height: 7)
                        Text(live.active ? "Working" : "Quiet")
                        Text("·")
                        Text(live.timestamp, style: .time)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else {
                    Label("Sampling…", systemImage: "clock")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 25).padding(.vertical, 18)

            Picker("View", selection: $tab) {
                Label("Live", systemImage: "waveform.path.ecg").tag(0)
                Label("History", systemImage: "chart.bar.xaxis").tag(1)
            }
            .pickerStyle(.segmented)
            .frame(width: 280)
            .padding(.bottom, 16)

            Divider()
            ScrollView {
                Group {
                    if tab == 0 { LiveView(model: model) }
                    else { HistoryView(model: model) }
                }
                .padding(25)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: tab) { _, newValue in
            if newValue == 1 { model.reloadHistory() }
        }
    }
}

private struct LiveView: View {
    @ObservedObject var model: MonitorModel
    private var total: ResourceUsage { model.live?.usage[.all] ?? ResourceUsage() }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
            }
            if model.scanFailed {
                Label(model.live == nil
                      ? "Process scan failed. Waiting for a valid reading."
                      : "Process scan failed. Showing the last valid reading.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
            } else if let count = model.live?.unreadableAgentProcesses, count > 0 {
                Label("\(count) agent processes could not be read. Totals may be low.", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
            }
            if model.live == nil {
                ContentUnavailableView("Waiting for process data", systemImage: "waveform.path",
                                       description: Text("Resource values will appear after a successful scan."))
            } else {
                HStack(alignment: .top, spacing: 14) {
                    MetricCard(title: "Physical memory", value: bytes(total.footprintBytes),
                               detail: "Combined agent footprint", symbol: "memorychip", tint: .teal,
                               prominent: true)
                    MetricCard(title: "CPU", value: String(format: "%.1f%%", total.cpuPercent),
                               detail: "100% = one CPU core", symbol: "cpu", tint: .indigo,
                               prominent: false)
                }
                HStack(spacing: 14) {
                    SmallMetric(title: "Processes", value: "\(total.processCount)", icon: "square.stack.3d.up")
                    SmallMetric(title: "SSD writes", value: bytesPerSecond(total.diskWriteBytesPerSecond),
                                icon: "internaldrive")
                    SmallMetric(title: "SSD reads", value: bytesPerSecond(total.diskReadBytesPerSecond),
                                icon: "arrow.down.to.line")
                }
                HStack {
                    Text("By harness").font(.headline)
                    Spacer()
                    Text("One live sample per second")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(Harness.individual) { harness in
                    HarnessRow(harness: harness, usage: model.live?.usage[harness] ?? ResourceUsage())
                }
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Last minute").font(.headline)
                        Spacer()
                        Text("Physical memory")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Chart(Array(model.recent.enumerated()), id: \.offset) { index, sample in
                        AreaMark(x: .value("Sample", index),
                                 y: .value("RAM", Double(sample.usage[.all]?.footprintBytes ?? 0) / 1_073_741_824))
                            .foregroundStyle(.teal.opacity(0.16))
                        LineMark(x: .value("Sample", index),
                                 y: .value("RAM", Double(sample.usage[.all]?.footprintBytes ?? 0) / 1_073_741_824))
                            .foregroundStyle(.teal)
                            .lineStyle(StrokeStyle(lineWidth: 2))
                    }
                    .chartYAxisLabel("GB")
                    .frame(height: 110)
                }
                .padding(18)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }
}

private struct MetricCard: View {
    let title: String
    let value: String
    let detail: String
    let symbol: String
    let tint: Color
    let prominent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: symbol)
                .font(.callout.weight(.medium))
                .foregroundStyle(tint)
            Text(value)
                .font(.system(size: prominent ? 42 : 34, weight: .semibold, design: .rounded))
                .contentTransition(.numericText())
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .leading)
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct SmallMetric: View {
    let title: String
    let value: String
    let icon: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.callout.weight(.semibold).monospacedDigit())
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 13))
    }
}

private struct HarnessRow: View {
    let harness: Harness
    let usage: ResourceUsage

    var body: some View {
        HStack(spacing: 13) {
            Circle().fill(color).frame(width: 9, height: 9)
            Text(harness.rawValue).font(.callout.weight(.medium))
            Spacer()
            if usage.processCount == 0 {
                Text("Not running").foregroundStyle(.secondary)
            } else {
                Text(bytes(usage.footprintBytes))
                    .frame(width: 110, alignment: .trailing)
                Text(String(format: "%.1f%% CPU", usage.cpuPercent))
                    .foregroundStyle(.secondary)
                    .frame(width: 105, alignment: .trailing)
                Text("\(usage.processCount) proc")
                    .foregroundStyle(.secondary)
                    .frame(width: 70, alignment: .trailing)
            }
        }
        .font(.callout.monospacedDigit())
        .padding(.horizontal, 16).padding(.vertical, 15)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var color: Color {
        switch harness { case .codex: .teal; case .claude: .orange; case .opencode: .purple; case .all: .gray }
    }
}

private struct HistoryView: View {
    @ObservedObject var model: MonitorModel

    private var active: [MinuteRecord] { model.history.filter(\.active) }
    private var ram: Percentiles { Percentiles(active.map(\.maxRAM)) }
    private var cpu: Percentiles { Percentiles(active.map(\.maxCPU)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 19) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("History").font(.system(size: 26, weight: .semibold, design: .rounded))
                    Text("Percentiles of each working minute’s highest 500 ms sample")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Harness", selection: $model.selectedHarness) {
                    ForEach(Harness.allCases) { Text($0.rawValue).tag($0) }
                }
                .frame(width: 150)
                Picker("Range", selection: $model.selectedDays) {
                    Text("1 day").tag(1)
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                }
                .frame(width: 145)
                Button { model.reloadHistory() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh history")
            }
            .onChange(of: model.selectedDays) { _, _ in model.reloadHistory() }
            .onChange(of: model.selectedHarness) { _, _ in model.reloadHistory() }

            if active.isEmpty {
                ContentUnavailableView("No working minutes yet", systemImage: "chart.bar.xaxis",
                                       description: Text("Keep Agent Monitor open while an agent works. History saves every 30 seconds."))
                    .frame(maxWidth: .infinity, minHeight: 320)
            } else {
                HStack(spacing: 14) {
                    SmallMetric(title: "Typical active minute · RAM",
                                value: bytes(UInt64(Percentiles(active.map(\.meanRAM)).p50)),
                                icon: "memorychip")
                    SmallMetric(title: "Typical active minute · CPU",
                                value: String(format: "%.1f%%", Percentiles(active.map(\.meanCPU)).p50),
                                icon: "cpu")
                }
                Text("Peaks within active minutes")
                    .font(.headline)
                HStack(spacing: 14) {
                    PercentileCard(title: "Physical memory", values: ram, format: { bytes(UInt64($0)) }, tint: .teal)
                    PercentileCard(title: "CPU", values: cpu, format: { String(format: "%.1f%%", $0) }, tint: .indigo)
                }
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Daily memory peak").font(.headline)
                        Spacer()
                        Text("Highest minute peak per day")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Chart(dailyPoints) { point in
                        BarMark(x: .value("Day", point.day), y: .value("GB", point.peakRAM / 1_073_741_824))
                            .foregroundStyle(.teal.gradient)
                            .cornerRadius(4)
                    }
                    .chartYAxisLabel("GB")
                    .frame(height: 180)
                }
                .padding(18)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                Text("\(active.count) working minutes · A minute counts when mean CPU is at least 5% of one core or mean SSD writes reach 100 KB/s. Open, idle apps stay in live RAM but usually stay out of these percentiles. Known processes are sampled every 500 ms; new subprocesses are discovered every 2 seconds, so shorter ones can be missed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = model.historyError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private var dailyPoints: [DailyPoint] {
        let groups = Dictionary(grouping: active) { record in
            Calendar.current.startOfDay(for: Date(timeIntervalSince1970: Double(record.minute) * 60))
        }
        return groups.map { day, records in
            DailyPoint(day: day, peakRAM: records.map(\.maxRAM).max() ?? 0,
                       peakCPU: records.map(\.maxCPU).max() ?? 0)
        }.sorted { $0.day < $1.day }
    }
}

private struct PercentileCard: View {
    let title: String
    let values: Percentiles
    let format: (Double) -> String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline).foregroundStyle(tint)
            ForEach([("P50", values.p50), ("P90", values.p90), ("P95", values.p95), ("P99", values.p99)], id: \.0) { label, value in
                HStack {
                    Text(label).foregroundStyle(.secondary)
                    Spacer()
                    Text(format(value)).fontWeight(.semibold).monospacedDigit()
                }
                .font(.callout)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct MenuBarContents: View {
    @ObservedObject var model: MonitorModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if model.scanFailed {
            Text("Agents · process scan unavailable")
        } else if let usage = model.live?.usage[.all] {
            Text("Agents · \(bytes(usage.footprintBytes)) RAM · \(String(format: "%.1f", usage.cpuPercent))% CPU")
        } else {
            Text("Sampling agents…")
        }
        Divider()
        Button("Open Agent Monitor") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut("m")
        Button("Quit Agent Monitor") { NSApp.terminate(nil) }
    }
}

private func bytes(_ value: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(min(value, UInt64(Int64.max))), countStyle: .memory)
}

private func bytesPerSecond(_ value: Double) -> String {
    bytes(UInt64(max(0, min(value, Double(UInt64.max))))) + "/s"
}
