// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "Audiogen", platforms: [.macOS("27.0")], products: [.executable(name: "Audiogen", targets: ["Audiogen"])], targets: [.executableTarget(name: "Audiogen", resources: [.process("Resources/ace-step.json"), .process("Resources/minimax.json"), .copy("Resources/MiniMaxRuntime"), .copy("Resources/PythonRuntimes")]), .testTarget(name: "AudiogenTests", dependencies: ["Audiogen"])])
