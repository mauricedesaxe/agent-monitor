// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "AgentMonitor",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "AgentMonitor", targets: ["AgentMonitor"])],
    targets: [
        .target(name: "MonitorCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "AgentMonitor", dependencies: ["MonitorCore"]),
        .executableTarget(name: "MonitorCoreChecks", dependencies: ["MonitorCore"],
                          path: "Tests/MonitorCoreChecks"),
    ]
)
