import Foundation

public final class Collector {
    private let queue = DispatchQueue(label: "AgentMonitor.collector", qos: .utility)
    private var timer: DispatchSourceTimer?
    private let sampleProvider: () -> LiveSample
    private let storeFactory: () throws -> HistoryStore
    private let dateProvider: () -> Date
    private var store: HistoryStore?
    private var buffer = MinuteBuffer()
    private var lastFlush = Date()
    private var sampleNumber = 0
    private var hydratedStore = false
    private var persistenceFailed = false
    public var onSample: ((LiveSample) -> Void)?
    public var onError: ((String?) -> Void)?

    public init() {
        let sampler = ProcessSampler()
        sampleProvider = sampler.sample
        storeFactory = { try HistoryStore() }
        dateProvider = Date.init
    }

    @_spi(Testing) public init(sampleProvider: @escaping () -> LiveSample,
                               storeFactory: @escaping () throws -> HistoryStore,
                               dateProvider: @escaping () -> Date) {
        self.sampleProvider = sampleProvider
        self.storeFactory = storeFactory
        self.dateProvider = dateProvider
    }

    @_spi(Testing) public func collectOnce() { queue.sync { tick() } }

    @_spi(Testing) public func flushNow() { queue.sync { flush() } }

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
        let sample = sampleProvider()
        let sampleMinute = Int64(sample.timestamp.timeIntervalSince1970 / 60)
        if store == nil {
            do {
                store = try storeFactory()
                try hydrateFromStore(including: sampleMinute)
            }
            catch {
                store = nil
                reportPersistenceError(error)
            }
        }
        if sample.scanFailed {
            onSample?(sample)
            return
        }
        buffer.add(sample)
        sampleNumber += 1
        if sampleNumber % 2 == 0 { onSample?(sample) }
        if dateProvider().timeIntervalSince(lastFlush) >= 30 {
            flush()
            lastFlush = dateProvider()
        }
    }

    private func flush() {
        guard let store else { return }
        let currentMinute = Int64(dateProvider().timeIntervalSince1970 / 60)
        do {
            try buffer.persist(currentMinute: currentMinute, using: store.upsert)
            if persistenceFailed {
                persistenceFailed = false
                onError?(nil)
            }
        }
        catch {
            reportPersistenceError(error)
            return
        }
    }

    private func reportPersistenceError(_ error: Error) {
        persistenceFailed = true
        onError?("History cannot be saved: \(error)")
    }

    private func hydrateFromStore(including sampleMinute: Int64) throws {
        guard let store, !hydratedStore else { return }
        let currentMinute = Int64(dateProvider().timeIntervalSince1970 / 60)
        let minutes = buffer.minutes.union([currentMinute, sampleMinute])
        for checkpoint in try store.checkpoints(for: minutes) {
            buffer.merge(checkpoint)
        }
        hydratedStore = true
    }
}
