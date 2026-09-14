import Foundation

/// One short-lived stdio connection. Only initialize, account/rateLimits/read and account/read; never starts a turn.
public struct CodexAppServerClient: Sendable {
    public let executable: URL
    public let dataDirectory: URL
    public let timeout: TimeInterval

    public init(executable: URL, dataDirectory: URL = CodexLocator.dataDirectory, timeout: TimeInterval = 30) {
        self.executable = executable
        self.dataDirectory = dataDirectory
        self.timeout = timeout
    }

    public func fetch() async throws -> CodexRateLimits {
        let worker = Task.detached(priority: .utility) { try run() }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private func run() throws -> CodexRateLimits {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = dataDirectory.path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        environment["PATH"] = "\(home)/.bun/bin:\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (environment["PATH"] ?? "")
        process.environment = environment
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let collector = LineCollector()
        output.fileHandleForReading.readabilityHandler = { handle in
            let bytes = handle.availableData
            if !bytes.isEmpty { collector.append(bytes) }
        }
        defer {
            output.fileHandleForReading.readabilityHandler = nil
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
        }
        try process.run()
        func send(_ message: [String: Any]) throws {
            var bytes = try JSONSerialization.data(withJSONObject: message)
            bytes.append(0x0A)
            try input.fileHandleForWriting.write(contentsOf: bytes)
        }
        try send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "agent_hud", "title": "Agent HUD", "version": "0.1.0"]]])
        let deadline = Date().addingTimeInterval(timeout)
        var limits: CodexRateLimits?
        var account: CodexRateLimits.SignedInAccount?
        var accountAnswered = false
        var graceUntil = Date.distantFuture
        while Date() < deadline {
            try Task.checkCancellation()
            for line in collector.drainLines() {
                guard let bytes = line.data(using: .utf8),
                      let message = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                      let id = message["id"] as? Int, (1...3).contains(id) else { continue }
                if let error = message["error"] as? [String: Any] {
                    // An engine without account/read still reports limits, only without the signed-in email.
                    guard id == 3 else { throw UsageProviderError("Codex: " + (error["message"] as? String ?? "app-server error")) }
                    accountAnswered = true
                    continue
                }
                guard let result = message["result"] else { continue }
                let data = try JSONSerialization.data(withJSONObject: result)
                switch id {
                case 1:
                    try send(["method": "initialized"])
                    try send(["id": 2, "method": "account/rateLimits/read"])
                    try send(["id": 3, "method": "account/read", "params": [String: Any]()])
                case 2:
                    limits = try JSONDecoder().decode(CodexRateLimits.self, from: data)
                    graceUntil = Date().addingTimeInterval(2)
                default:
                    account = try? JSONDecoder().decode(AccountResponse.self, from: data).account
                    accountAnswered = true
                }
            }
            if var reading = limits, accountAnswered || Date() >= graceUntil || !process.isRunning {
                reading.account = account
                return reading
            }
            if !process.isRunning {
                throw UsageProviderError(L10n.text("Codex 引擎提前退出，请检查本机登录状态", "Codex exited before reporting limits; check local sign-in"))
            }
            Thread.sleep(forTimeInterval: 0.025)
        }
        throw UsageProviderError(L10n.text("Codex 额度查询超时", "Codex quota query timed out"))
    }
}

private struct AccountResponse: Decodable {
    let account: CodexRateLimits.SignedInAccount?
}
