import Foundation
@_spi(Testing) import MonitorCore

struct AttributionCase {
    let ownPID: Int32
    let readings: [ProcessReading]
    let expectedOwners: [Int32: Harness]

    static func make(random: inout CaseRandom) -> Self {
        var nextPID = Int32(100 + random.integer(10_000))
        func pid() -> Int32 {
            defer { nextPID += 1 }
            return nextPID
        }
        func reading(_ pid: Int32, parent: Int32, name: String, path: String) -> ProcessReading {
            ProcessReading(pid: pid, parentPID: parent, name: name, path: path,
                           startTicks: 1, cpuTicks: UInt64(pid), footprintBytes: 1024)
        }

        let ownPID = pid()
        var readings = [reading(ownPID, parent: 1, name: "AgentMonitor", path: "/Applications/AgentMonitor.app")]
        var expected: [Int32: Harness] = [:]
        let ownChild = pid()
        readings.append(reading(ownChild, parent: ownPID, name: "codex", path: "/usr/bin/codex"))
        let ownGrandchild = pid()
        readings.append(reading(ownGrandchild, parent: ownChild, name: "claude", path: "/usr/bin/claude"))

        for (harness, name, path) in [
            (Harness.codex, "codex", "/usr/local/bin/codex"),
            (.claude, "claude", "/usr/local/bin/claude"),
            (.opencode, "opencode", "/usr/local/bin/opencode"),
        ] {
            let root = pid()
            readings.append(reading(root, parent: 1, name: name, path: path))
            expected[root] = harness
            var parents = [root]
            for _ in 0..<(1 + random.integer(5)) {
                let child = pid()
                let parent = parents[random.integer(parents.count)]
                readings.append(reading(child, parent: parent, name: "node", path: "/usr/bin/node"))
                expected[child] = harness
                parents.append(child)
            }
            let helper = pid()
            let helperName = random.bool() ? "crashpad_handler" : "updater"
            readings.append(reading(helper, parent: root, name: helperName, path: "/usr/bin/\(helperName)"))
            let helperChild = pid()
            readings.append(reading(helperChild, parent: helper, name: "node", path: "/usr/bin/node"))
        }

        let orphan = pid()
        readings.append(reading(orphan, parent: 0, name: "node", path: "/usr/bin/node"))
        let orphanChild = pid()
        readings.append(reading(orphanChild, parent: orphan, name: "node", path: "/usr/bin/node"))
        let cycleA = pid()
        let cycleB = pid()
        readings.append(reading(cycleA, parent: cycleB, name: "node", path: "/usr/bin/node"))
        readings.append(reading(cycleB, parent: cycleA, name: "node", path: "/usr/bin/node"))
        random.shuffle(&readings)
        return Self(ownPID: ownPID, readings: readings, expectedOwners: expected)
    }

    func check() throws {
        for rotation in 0..<min(readings.count, 8) {
            let ordered = Array(readings[rotation...]) + Array(readings[..<rotation])
            let actual = ProcessAttribution.classify(ordered, excluding: ownPID)
            guard actual == expectedOwners else {
                let expected = expectedOwners.sorted { $0.key < $1.key }
                    .map { "\($0.key)=\($0.value.rawValue)" }.joined(separator: ",")
                let found = actual.sorted { $0.key < $1.key }
                    .map { "\($0.key)=\($0.value.rawValue)" }.joined(separator: ",")
                throw FuzzFailure("ownership map differs at rotation \(rotation); expected [\(expected)], got [\(found)]")
            }
        }
    }

    func describe() -> String {
        "own=\(ownPID) readings=[" + readings.map {
            "\($0.pid):\($0.parentPID):\($0.name):\($0.path)"
        }.joined(separator: ",") + "]"
    }
}
