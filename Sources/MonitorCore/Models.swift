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
    public let cpuSum: Double
    public let ramSum: Double
    public let diskWriteSum: Double
    public let legacyActivityFloor: Bool

    public init(minute: Int64, harness: Harness, sampleCount: Int, active: Bool,
                meanCPU: Double, maxCPU: Double, meanRAM: Double, maxRAM: Double,
                maxDiskWriteRate: Double, cpuSum: Double? = nil, ramSum: Double? = nil,
                diskWriteSum: Double? = nil, legacyActivityFloor: Bool = false) {
        self.minute = minute
        self.harness = harness
        self.sampleCount = sampleCount
        self.active = active
        self.meanCPU = meanCPU
        self.maxCPU = maxCPU
        self.meanRAM = meanRAM
        self.maxRAM = maxRAM
        self.maxDiskWriteRate = maxDiskWriteRate
        self.cpuSum = cpuSum ?? meanCPU * Double(sampleCount)
        self.ramSum = ramSum ?? meanRAM * Double(sampleCount)
        self.diskWriteSum = diskWriteSum ?? 0
        self.legacyActivityFloor = legacyActivityFloor
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
    private var legacyActivityFloor = false

    public init() {}

    public init(checkpoint: MinuteRecord) {
        count = checkpoint.sampleCount
        cpuSum = checkpoint.cpuSum
        ramSum = checkpoint.ramSum
        maxCPU = checkpoint.maxCPU
        maxRAM = checkpoint.maxRAM
        maxDiskWriteRate = checkpoint.maxDiskWriteRate
        diskWriteSum = checkpoint.diskWriteSum
        legacyActivityFloor = checkpoint.legacyActivityFloor
    }

    public mutating func add(_ usage: ResourceUsage) {
        count += 1
        cpuSum += usage.cpuPercent
        ramSum += Double(usage.footprintBytes)
        maxCPU = max(maxCPU, usage.cpuPercent)
        maxRAM = max(maxRAM, Double(usage.footprintBytes))
        maxDiskWriteRate = max(maxDiskWriteRate, usage.diskWriteBytesPerSecond)
        diskWriteSum += usage.diskWriteBytesPerSecond
    }

    public mutating func merge(_ other: MinuteAccumulator) {
        count += other.count
        cpuSum += other.cpuSum
        ramSum += other.ramSum
        maxCPU = max(maxCPU, other.maxCPU)
        maxRAM = max(maxRAM, other.maxRAM)
        maxDiskWriteRate = max(maxDiskWriteRate, other.maxDiskWriteRate)
        diskWriteSum += other.diskWriteSum
        legacyActivityFloor = legacyActivityFloor || other.legacyActivityFloor
    }

    public func record(minute: Int64, harness: Harness) -> MinuteRecord? {
        guard count > 0 else { return nil }
        let meanCPU = cpuSum / Double(count)
        let working = legacyActivityFloor || meanCPU >= 5 || diskWriteSum / Double(count) >= 100 * 1024
        return MinuteRecord(minute: minute, harness: harness, sampleCount: count,
                            active: working, meanCPU: meanCPU, maxCPU: maxCPU,
                            meanRAM: ramSum / Double(count), maxRAM: maxRAM,
                            maxDiskWriteRate: maxDiskWriteRate, cpuSum: cpuSum,
                            ramSum: ramSum, diskWriteSum: diskWriteSum,
                            legacyActivityFloor: legacyActivityFloor)
    }
}

@_spi(Testing) public struct MinuteBuffer {
    private var accumulators: [Int64: [Harness: MinuteAccumulator]] = [:]

    public init() {}

    public var minutes: Set<Int64> { Set(accumulators.keys) }

    public mutating func add(_ sample: LiveSample) {
        let minute = Int64(sample.timestamp.timeIntervalSince1970 / 60)
        var byHarness = accumulators[minute] ?? [:]
        for harness in Harness.allCases {
            var accumulator = byHarness[harness] ?? MinuteAccumulator()
            accumulator.add(sample.usage[harness] ?? ResourceUsage())
            byHarness[harness] = accumulator
        }
        accumulators[minute] = byHarness
    }

    public mutating func merge(_ checkpoint: MinuteRecord) {
        var byHarness = accumulators[checkpoint.minute] ?? [:]
        var accumulator = byHarness[checkpoint.harness] ?? MinuteAccumulator()
        accumulator.merge(MinuteAccumulator(checkpoint: checkpoint))
        byHarness[checkpoint.harness] = accumulator
        accumulators[checkpoint.minute] = byHarness
    }

    public func records() -> [MinuteRecord] {
        accumulators.flatMap { minute, byHarness in
            byHarness.compactMap { harness, accumulator in
                accumulator.record(minute: minute, harness: harness)
            }
        }
    }

    public mutating func persist(currentMinute: Int64,
                                 using writer: ([MinuteRecord]) throws -> Void) throws {
        try writer(records())
        accumulators = accumulators.filter { $0.key >= currentMinute }
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
