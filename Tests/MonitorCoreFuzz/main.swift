import Darwin
import Foundation
@_spi(Testing) import MonitorCore

enum FuzzDomain: String, CaseIterable {
    case attribution
    case history
    case all

    var salt: UInt64 {
        switch self {
        case .attribution: 0xA771B071
        case .history: 0xB1570A11
        case .all: 0
        }
    }
}

enum CaseSelection {
    case count(Int)
    case one(Int)
}

struct FuzzOptions {
    let domain: FuzzDomain
    let seed: UInt64
    let selection: CaseSelection

    static func parse(_ arguments: [String]) throws -> Self {
        var domain: FuzzDomain = .all
        var seed: UInt64 = 12_648_430
        var iterations: Int?
        var oneCase: Int?
        var index = 0
        while index < arguments.count {
            let value = arguments[index]
            guard index + 1 < arguments.count else { throw FuzzFailure("missing value for \(value)") }
            let next = arguments[index + 1]
            switch value {
            case "--domain":
                guard let parsed = FuzzDomain(rawValue: next) else { throw FuzzFailure("invalid domain \(next)") }
                domain = parsed
            case "--seed":
                guard let parsed = UInt64(next) else { throw FuzzFailure("invalid seed \(next)") }
                seed = parsed
            case "--iterations":
                guard let parsed = Int(next), (1...100_000).contains(parsed), iterations == nil else {
                    throw FuzzFailure("iterations must be 1...100000 and appear once")
                }
                iterations = parsed
            case "--case":
                guard let parsed = Int(next), (0...99_999).contains(parsed), oneCase == nil else {
                    throw FuzzFailure("case must be 0...99999 and appear once")
                }
                oneCase = parsed
            default:
                throw FuzzFailure("unknown option \(value)")
            }
            index += 2
        }
        guard iterations == nil || oneCase == nil else { throw FuzzFailure("choose --iterations or --case") }
        guard oneCase == nil || domain != .all else { throw FuzzFailure("--case requires one domain") }
        return Self(domain: domain, seed: seed,
                    selection: oneCase.map(CaseSelection.one) ?? .count(iterations ?? 50))
    }
}

struct FuzzFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

struct CaseRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        return value ^ (value >> 31)
    }

    mutating func integer(_ upperBound: Int) -> Int {
        precondition(upperBound > 0)
        return Int(next() % UInt64(upperBound))
    }

    mutating func bool() -> Bool { integer(2) == 0 }

    mutating func shuffle<T>(_ values: inout [T]) {
        guard values.count > 1 else { return }
        for index in stride(from: values.count - 1, through: 1, by: -1) {
            values.swapAt(index, integer(index + 1))
        }
    }
}

func caseSeed(_ seed: UInt64, domain: FuzzDomain, index: Int) -> UInt64 {
    var random = CaseRandom(seed: seed ^ domain.salt ^ (UInt64(index) &* 0xD1B54A32D192ED03))
    return random.next()
}

func runCase(_ domain: FuzzDomain, seed: UInt64, index: Int) throws {
    var random = CaseRandom(seed: caseSeed(seed, domain: domain, index: index))
    switch domain {
    case .attribution:
        let fixture = AttributionCase.make(random: &random)
        do { try fixture.check() }
        catch {
            throw FuzzFailure("invariant: \(error)\nfixture: \(fixture.describe())")
        }
    case .history:
        let fixture = HistoryCase.make(random: &random)
        do { try fixture.check() }
        catch {
            throw FuzzFailure("invariant: \(error)\nfixture: \(fixture.describe())")
        }
    case .all:
        preconditionFailure("a case must have a concrete domain")
    }
}

do {
    let options = try FuzzOptions.parse(Array(CommandLine.arguments.dropFirst()))
    let domains: [FuzzDomain] = options.domain == .all ? [.attribution, .history] : [options.domain]
    let cases: [Int]
    switch options.selection {
    case .count(let count): cases = Array(0..<count)
    case .one(let index): cases = [index]
    }
    for domain in domains {
        for index in cases {
            do { try runCase(domain, seed: options.seed, index: index) }
            catch {
                fputs("Fuzz failure domain=\(domain.rawValue) seed=\(options.seed) case=\(index)\n\(error)\n", stderr)
                fputs("Replay: CLANG_MODULE_CACHE_PATH=/private/tmp/agent-monitor-clang-cache swift run --disable-sandbox MonitorCoreFuzz --domain \(domain.rawValue) --seed \(options.seed) --case \(index)\n", stderr)
                exit(EXIT_FAILURE)
            }
        }
    }
    print("Fuzz passed domains=\(domains.map { $0.rawValue }.joined(separator: ",")) seed=\(options.seed) cases=\(cases.count) each")
} catch {
    fputs("\(error)\nUsage: MonitorCoreFuzz [--domain attribution|history|all] [--seed UInt64] [--iterations 1...100000 | --case 0...99999]\n", stderr)
    exit(EXIT_FAILURE)
}
