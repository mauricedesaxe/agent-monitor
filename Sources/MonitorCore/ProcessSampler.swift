import Darwin
import Foundation

public struct ProcessReading: Sendable {
    public let pid: Int32
    public let parentPID: Int32
    public let name: String
    public let path: String
    public let startTicks: UInt64
    public let cpuTicks: UInt64
    public let footprintBytes: UInt64
    public let diskReadBytes: UInt64
    public let diskWriteBytes: UInt64

    public init(pid: Int32, parentPID: Int32, name: String, path: String,
                startTicks: UInt64, cpuTicks: UInt64, footprintBytes: UInt64,
                diskReadBytes: UInt64 = 0, diskWriteBytes: UInt64 = 0) {
        self.pid = pid
        self.parentPID = parentPID
        self.name = name
        self.path = path
        self.startTicks = startTicks
        self.cpuTicks = cpuTicks
        self.footprintBytes = footprintBytes
        self.diskReadBytes = diskReadBytes
        self.diskWriteBytes = diskWriteBytes
    }
}

public enum ProcessAttribution {
    public static func classify(_ processes: [ProcessReading], excluding ownPID: Int32) -> [Int32: Harness] {
        let byPID = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [Int32: Harness] = [:]
        var excluded: Set<Int32> = [ownPID]
        var unmatched: Set<Int32> = []
        let children = Dictionary(grouping: processes, by: \.parentPID)
        var toExclude = [ownPID]
        while let parent = toExclude.popLast() {
            for child in children[parent] ?? [] where excluded.insert(child.pid).inserted {
                toExclude.append(child.pid)
            }
        }

        func owner(of pid: Int32, visiting: inout Set<Int32>) -> Harness? {
            if excluded.contains(pid) { return nil }
            if let known = result[pid] { return known }
            if unmatched.contains(pid) { return nil }
            guard let process = byPID[pid], !visiting.contains(pid) else { return nil }
            visiting.insert(pid)
            defer { visiting.remove(pid) }
            if process.parentPID == ownPID || excluded.contains(process.parentPID) {
                excluded.insert(pid)
                return nil
            }
            let label = (process.name + " " + process.path).lowercased()
            if label.contains("crashpad") || label.contains("updater") || label.contains("update helper") {
                excluded.insert(pid)
                return nil
            }
            if let root = rootHarness(process) {
                result[pid] = root
                return root
            }
            if let parent = owner(of: process.parentPID, visiting: &visiting) {
                result[pid] = parent
                return parent
            }
            unmatched.insert(pid)
            return nil
        }

        for process in processes {
            var visiting: Set<Int32> = []
            _ = owner(of: process.pid, visiting: &visiting)
        }
        return result
    }

    private static func rootHarness(_ process: ProcessReading) -> Harness? {
        let name = process.name.lowercased()
        let path = process.path.lowercased()
        if name == "codex" || name.hasPrefix("codex helper") || name.hasPrefix("codex-cli")
            || path.contains("/codex.app/") || path.contains("/codex framework.framework/")
            || path.contains("/.codex/computer-use/") {
            return .codex
        }
        if name == "claude" || name == "claude code" || name.hasPrefix("claude helper")
            || path.contains("/claude.app/") || path.contains("/claude code.app/")
            || path.contains("/.local/share/claude/versions/") {
            return .claude
        }
        if name == "opencode" || name.hasPrefix("opencode helper") || path.contains("/opencode.app/") {
            return .opencode
        }
        return nil
    }
}

private struct ProcessKey: Hashable {
    let pid: Int32
    let startTicks: UInt64
}

public final class ProcessSampler {
    private var prior: [ProcessKey: ProcessReading] = [:]
    private var priorTime: UInt64?
    private var known: [ProcessReading] = []
    private var knownOwners: [Int32: Harness] = [:]
    private var lastDiscovery: UInt64?
    private var lastUnreadable = 0
    private let ownPID = getpid()
    private let timebase: mach_timebase_info_data_t
    private let discoveryIntervalNanos: UInt64
    private let clock: () -> UInt64
    private let discoveryReader: (() -> ([ProcessReading], [Int32: Harness], Int, Bool))?
    private let knownProcessReader: (([ProcessReading]) -> ([ProcessReading], Int))?

    public init(discoveryIntervalSeconds: Double = 2) {
        self.discoveryIntervalNanos = UInt64(max(0.5, discoveryIntervalSeconds) * 1_000_000_000)
        self.clock = { DispatchTime.now().uptimeNanoseconds }
        self.discoveryReader = nil
        self.knownProcessReader = nil
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        timebase = info
    }

    @_spi(Testing) public init(discoveryIntervalSeconds: Double = 2, clock: @escaping () -> UInt64,
                               discoveryReader: @escaping () -> ([ProcessReading], [Int32: Harness], Int, Bool),
                               knownProcessReader: @escaping ([ProcessReading]) -> ([ProcessReading], Int)) {
        discoveryIntervalNanos = UInt64(max(0.5, discoveryIntervalSeconds) * 1_000_000_000)
        self.clock = clock
        self.discoveryReader = discoveryReader
        self.knownProcessReader = knownProcessReader
        var info = mach_timebase_info_data_t()
        info.numer = 1
        info.denom = 1
        self.timebase = info
    }

    public func sample() -> LiveSample {
        let now = clock()
        let shouldDiscover = lastDiscovery.map { now - $0 >= discoveryIntervalNanos } ?? true
        var readings: [ProcessReading]
        var unreadableCount: Int
        if shouldDiscover {
            let discovery = discoveryReader?() ?? readProcesses()
            if !discovery.3 {
                known = discovery.0
                knownOwners = discovery.1
                lastUnreadable = discovery.2
            } else {
                lastDiscovery = now
                let usage = Dictionary(uniqueKeysWithValues: Harness.allCases.map { ($0, ResourceUsage()) })
                return LiveSample(timestamp: Date(), usage: usage, active: false,
                                  unreadableAgentProcesses: lastUnreadable, scanFailed: true)
            }
            lastDiscovery = now
            readings = known
            unreadableCount = lastUnreadable
        } else {
            (readings, unreadableCount) = knownProcessReader?(known) ?? pollKnown()
            unreadableCount = max(lastUnreadable, unreadableCount)
        }
        let attribution = knownOwners
        let elapsed = priorTime.map { Double(now - $0) / 1_000_000_000 } ?? 0
        var usage = Dictionary(uniqueKeysWithValues: Harness.allCases.map { ($0, ResourceUsage()) })
        var current: [ProcessKey: ProcessReading] = [:]
        for process in readings {
            let key = ProcessKey(pid: process.pid, startTicks: process.startTicks)
            current[key] = process
            guard let harness = attribution[process.pid] else { continue }
            var item = usage[harness] ?? ResourceUsage()
            item.processCount += 1
            item.footprintBytes += process.footprintBytes
            if let previous = prior[key], elapsed > 0 {
                let cpuDelta = process.cpuTicks >= previous.cpuTicks ? process.cpuTicks - previous.cpuTicks : 0
                let cpuNanos = Double(cpuDelta) * Double(timebase.numer) / Double(timebase.denom)
                item.cpuPercent += cpuNanos / (elapsed * 1_000_000_000) * 100
                let readDelta = process.diskReadBytes >= previous.diskReadBytes
                    ? process.diskReadBytes - previous.diskReadBytes : 0
                let writeDelta = process.diskWriteBytes >= previous.diskWriteBytes
                    ? process.diskWriteBytes - previous.diskWriteBytes : 0
                item.diskReadBytesPerSecond += Double(readDelta) / elapsed
                item.diskWriteBytesPerSecond += Double(writeDelta) / elapsed
            }
            usage[harness] = item
        }
        var combined = ResourceUsage()
        for harness in Harness.individual { combined.add(usage[harness] ?? ResourceUsage()) }
        usage[.all] = combined
        prior = current
        priorTime = now
        let active = combined.cpuPercent >= 5 || combined.diskWriteBytesPerSecond >= 100 * 1024
        return LiveSample(timestamp: Date(), usage: usage, active: active,
                          unreadableAgentProcesses: unreadableCount, scanFailed: false)
    }

    private func pollKnown() -> ([ProcessReading], Int) {
        var readings: [ProcessReading] = []
        readings.reserveCapacity(known.count)
        var unreadable = 0
        for process in known {
            var rusage = rusage_info_v4()
            let status = withUnsafeMutablePointer(to: &rusage) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(process.pid, RUSAGE_INFO_V4, $0)
                }
            }
            guard status == 0 else {
                if errno == EPERM || errno == EACCES { unreadable += 1 }
                continue
            }
            guard rusage.ri_proc_start_abstime == process.startTicks else { continue }
            readings.append(ProcessReading(pid: process.pid, parentPID: process.parentPID,
                                           name: process.name, path: process.path,
                                           startTicks: rusage.ri_proc_start_abstime,
                                           cpuTicks: rusage.ri_user_time + rusage.ri_system_time,
                                           footprintBytes: rusage.ri_phys_footprint,
                                           diskReadBytes: rusage.ri_diskio_bytesread,
                                           diskWriteBytes: rusage.ri_diskio_byteswritten))
        }
        return (readings, unreadable)
    }

    private func readProcesses() -> ([ProcessReading], [Int32: Harness], Int, Bool) {
        let capacity = max(1024, Int(proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)) / MemoryLayout<Int32>.stride + 256)
        var pids = [Int32](repeating: 0, count: capacity)
        let bytes = pids.withUnsafeMutableBytes { buffer in
            proc_listpids(UInt32(PROC_ALL_PIDS), 0, buffer.baseAddress, Int32(buffer.count))
        }
        guard bytes > 0 else { return ([], [:], 0, true) }
        var metadata: [ProcessReading] = []
        metadata.reserveCapacity(Int(bytes) / MemoryLayout<Int32>.stride)
        for pid in pids.prefix(Int(bytes) / MemoryLayout<Int32>.stride) where pid > 0 {
            var bsd = proc_bsdinfo()
            let bsdBytes = withUnsafeMutablePointer(to: &bsd) {
                proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, $0, Int32(MemoryLayout<proc_bsdinfo>.size))
            }
            guard bsdBytes == MemoryLayout<proc_bsdinfo>.size,
                  bsd.pbi_flags & UInt32(PROC_FLAG_INEXIT) == 0,
                  bsd.pbi_status != UInt32(SZOMB) else { continue }
            let name = withUnsafePointer(to: bsd.pbi_name) {
                String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
            }
            var pathBuffer = [CChar](repeating: 0, count: 4096)
            let pathLength = pathBuffer.withUnsafeMutableBufferPointer {
                proc_pidpath(pid, $0.baseAddress, UInt32($0.count))
            }
            let path = pathLength > 0 ? String(cString: pathBuffer) : ""
            metadata.append(ProcessReading(pid: pid, parentPID: Int32(bsd.pbi_ppid), name: name,
                                           path: path, startTicks: 0, cpuTicks: 0, footprintBytes: 0))
        }
        let owned = ProcessAttribution.classify(metadata, excluding: ownPID)
        var readings: [ProcessReading] = []
        readings.reserveCapacity(owned.count)
        var unreadable = 0
        for process in metadata where owned[process.pid] != nil {
            var rusage = rusage_info_v4()
            let status = withUnsafeMutablePointer(to: &rusage) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(process.pid, RUSAGE_INFO_V4, $0)
                }
            }
            guard status == 0 else { unreadable += 1; continue }
            readings.append(ProcessReading(pid: process.pid, parentPID: process.parentPID,
                                           name: process.name, path: process.path,
                                           startTicks: rusage.ri_proc_start_abstime,
                                           cpuTicks: rusage.ri_user_time + rusage.ri_system_time,
                                           footprintBytes: rusage.ri_phys_footprint,
                                           diskReadBytes: rusage.ri_diskio_bytesread,
                                           diskWriteBytes: rusage.ri_diskio_byteswritten))
        }
        return (readings, owned, unreadable, false)
    }
}
