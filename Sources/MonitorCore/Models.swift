import Foundation

public enum Harness: String, CaseIterable, Codable, Identifiable, Sendable {
    case all = "All agents"
    case codex = "Codex"
    case claude = "Claude Code"
    case opencode = "OpenCode"

    public var id: String { rawValue }
    public static var individual: [Harness] { [.codex, .claude, .opencode] }
}

public struct ResourceUsage: Sendable {
    public var cpuPercent: Double
    public var footprintBytes: UInt64
    public var diskReadBytesPerSecond: Double
    public var diskWriteBytesPerSecond: Double
    public var processCount: Int

    public init(cpuPercent: Double = 0, footprintBytes: UInt64 = 0,
                diskReadBytesPerSecond: Double = 0, diskWriteBytesPerSecond: Double = 0,
                processCount: Int = 0) {
        self.cpuPercent = cpuPercent
        self.footprintBytes = footprintBytes
        self.diskReadBytesPerSecond = diskReadBytesPerSecond
        self.diskWriteBytesPerSecond = diskWriteBytesPerSecond
        self.processCount = processCount
    }

    public mutating func add(_ other: ResourceUsage) {
        cpuPercent += other.cpuPercent
        footprintBytes += other.footprintBytes
        diskReadBytesPerSecond += other.diskReadBytesPerSecond
        diskWriteBytesPerSecond += other.diskWriteBytesPerSecond
        processCount += other.processCount
    }
}

public struct LiveSample: Sendable {
    public let timestamp: Date
    public let usage: [Harness: ResourceUsage]
    public let active: Bool
    public let unreadableAgentProcesses: Int
    public let scanFailed: Bool

    public init(timestamp: Date, usage: [Harness: ResourceUsage], active: Bool,
                unreadableAgentProcesses: Int = 0, scanFailed: Bool = false) {
        self.timestamp = timestamp
        self.usage = usage
        self.active = active
        self.unreadableAgentProcesses = unreadableAgentProcesses
        self.scanFailed = scanFailed
    }
}

public struct MinuteRecord: Sendable {
    public let minute: Int64
    public let harness: Harness
    public let sampleCount: Int
    public let active: Bool
    public let meanCPU: Double
    public let maxCPU: Double
    public let meanRAM: Double
    public let maxRAM: Double
    public let maxDiskWriteRate: Double

    public init(minute: Int64, harness: Harness, sampleCount: Int, active: Bool,
                meanCPU: Double, maxCPU: Double, meanRAM: Double, maxRAM: Double,
                maxDiskWriteRate: Double) {
        self.minute = minute
        self.harness = harness
        self.sampleCount = sampleCount
        self.active = active
        self.meanCPU = meanCPU
        self.maxCPU = maxCPU
        self.meanRAM = meanRAM
        self.maxRAM = maxRAM
        self.maxDiskWriteRate = maxDiskWriteRate
    }
}

public struct MinuteAccumulator {
    private var count = 0
    private var cpuSum = 0.0
    private var ramSum = 0.0
    private var maxCPU = 0.0
    private var maxRAM = 0.0
    private var maxDiskWriteRate = 0.0
    private var diskWriteSum = 0.0

    public init() {}

    public mutating func add(_ usage: ResourceUsage, active isActive: Bool) {
        count += 1
        cpuSum += usage.cpuPercent
        ramSum += Double(usage.footprintBytes)
        maxCPU = max(maxCPU, usage.cpuPercent)
        maxRAM = max(maxRAM, Double(usage.footprintBytes))
        maxDiskWriteRate = max(maxDiskWriteRate, usage.diskWriteBytesPerSecond)
        diskWriteSum += usage.diskWriteBytesPerSecond
    }

    public func record(minute: Int64, harness: Harness) -> MinuteRecord? {
        guard count > 0 else { return nil }
        let meanCPU = cpuSum / Double(count)
        let working = count >= 20 && (meanCPU >= 5 || diskWriteSum / Double(count) >= 100 * 1024)
        return MinuteRecord(minute: minute, harness: harness, sampleCount: count,
                            active: working, meanCPU: meanCPU, maxCPU: maxCPU,
                            meanRAM: ramSum / Double(count), maxRAM: maxRAM,
                            maxDiskWriteRate: maxDiskWriteRate)
    }
}

public struct Percentiles: Sendable {
    public let p50: Double
    public let p90: Double
    public let p95: Double
    public let p99: Double

    public init(_ values: [Double]) {
        let sorted = values.sorted()
        func value(_ p: Double) -> Double {
            guard !sorted.isEmpty else { return 0 }
            let position = Double(sorted.count - 1) * p
            let lower = Int(position)
            let fraction = position - Double(lower)
            guard lower + 1 < sorted.count else { return sorted[lower] }
            return sorted[lower] + (sorted[lower + 1] - sorted[lower]) * fraction
        }
        p50 = value(0.5)
        p90 = value(0.9)
        p95 = value(0.95)
        p99 = value(0.99)
    }
}

public struct DailyPoint: Identifiable, Sendable {
    public let day: Date
    public let peakRAM: Double
    public let peakCPU: Double
    public var id: Date { day }

    public init(day: Date, peakRAM: Double, peakCPU: Double) {
        self.day = day
        self.peakRAM = peakRAM
        self.peakCPU = peakCPU
    }
}
