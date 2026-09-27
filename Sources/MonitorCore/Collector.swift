import Foundation

public final class Collector {
    private let queue = DispatchQueue(label: "AgentMonitor.collector", qos: .utility)
    private var timer: DispatchSourceTimer?
    private let sampler = ProcessSampler()
    private var store: HistoryStore?
    private var accumulators: [Int64: [Harness: MinuteAccumulator]] = [:]
    private var lastFlush = Date()
    private var sampleNumber = 0
    public var onSample: ((LiveSample) -> Void)?
    public var onError: ((String) -> Void)?

    public init() {}

    public func start() {
        guard timer == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now(), repeating: .milliseconds(500), leeway: .milliseconds(20))
        source.setEventHandler { [weak self] in self?.tick() }
        timer = source
        source.resume()
    }

    public func stop() {
        timer?.cancel()
        timer = nil
        queue.sync { flush() }
    }

    private func tick() {
        if store == nil {
            do { store = try HistoryStore() }
            catch { onError?("History cannot be saved: \(error)") }
        }
        let sample = sampler.sample()
        let minute = Int64(sample.timestamp.timeIntervalSince1970 / 60)
        var byHarness = accumulators[minute] ?? [:]
        for harness in Harness.allCases {
            var accumulator = byHarness[harness] ?? MinuteAccumulator()
            accumulator.add(sample.usage[harness] ?? ResourceUsage(), active: sample.active)
            byHarness[harness] = accumulator
        }
        accumulators[minute] = byHarness
        sampleNumber += 1
        if sampleNumber % 2 == 0 { onSample?(sample) }
        if Date().timeIntervalSince(lastFlush) >= 30 {
            flush()
            lastFlush = Date()
        }
    }

    private func flush() {
        let records = accumulators.flatMap { minute, byHarness in
            byHarness.compactMap { harness, accumulator in
                accumulator.record(minute: minute, harness: harness)
            }
        }
        do { try store?.upsert(records) }
        catch { onError?("History cannot be saved: \(error)") }
        let currentMinute = Int64(Date().timeIntervalSince1970 / 60)
        accumulators = accumulators.filter { $0.key >= currentMinute }
    }
}
