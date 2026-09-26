import AgentHUDSupport
import Foundation

/// OMP / Pi attention inbox under `<agent-home>/agent-hud/attention`.
///
/// The OMP `agent-hud.ts` extension keeps one file per session while `ask` or a tool approval is open, and deletes it
/// when the wait ends. Presence means the client still needs the user — unlike Claude's notification hook, a newer
/// turn heartbeat must not clear it. When that observer is installed, absence is equally authoritative: a turn file
/// left at `waitingForApproval` after the inbox cleared is stale and must not keep the island on "Needs you".
enum OpenAgentAttention {
    struct Event: Equatable, Sendable {
        let sessionID: String
        let message: String?
        let observedAt: Date
    }

    static let retention: TimeInterval = 86400
    static let messageLength = 2048
    static let attentionObserverMarker = "// Agent HUD Omp attention observer\n"

    /// Distinct attention directories under each agent home the HUD watches.
    static func directories(in paths: OpenAgentPaths) -> [URL] {
        paths.agentHomes.map { $0.appendingPathComponent("agent-hud/attention") }
    }

    /// True when OMP's attention observer owns `extensions/agent-hud.ts`, so the inbox — not a leftover turn snapshot —
    /// decides whether a session still needs the user.
    static func isInboxAuthoritative(in paths: OpenAgentPaths) -> Bool {
        paths.agentHomes.contains { home in
            let file = home.appendingPathComponent("extensions/agent-hud.ts")
            return (try? String(contentsOf: file, encoding: .utf8))?.hasPrefix(attentionObserverMarker) == true
        }
    }

    /// Pending requests keyed so both raw OMP ids and the `pi:` turn namespace resolve.
    static func read(directories: [URL], now: Date = Date()) -> [String: Event] {
        var result: [String: Event] = [:]
        for folder in directories {
            let files = (try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.pathExtension == "json" {
                guard let data = try? Data(contentsOf: file), data.count <= 64 * 1024,
                      let event = parse(data),
                      event.observedAt > now.addingTimeInterval(-retention),
                      event.observedAt <= now.addingTimeInterval(60) else { continue }
                for key in keys(for: event.sessionID) {
                    if let existing = result[key], existing.observedAt >= event.observedAt { continue }
                    result[key] = event
                }
            }
        }
        return result
    }

    /// An attention file means the client still needs the user. OMP's `ask` can outlive `agent_end`, so the newest
    /// finished turn of that session is reopened as waiting rather than left completed while the dialog is open.
    /// When the inbox is authoritative and a session has no file, an OMP turn still marked waiting is released.
    static func awaiting(_ turns: [SessionTurn], requests: [String: Event],
                         inboxAuthoritative: Bool = false, now: Date = Date()) -> [SessionTurn] {
        if requests.isEmpty && !inboxAuthoritative { return turns }
        var newestFinished: [String: Int] = [:]
        for (index, turn) in turns.enumerated() where turn.state == .completed || turn.state == .ended {
            if let previous = newestFinished[turn.sessionID],
               turns[previous].observedAtMs > turn.observedAtMs { continue }
            newestFinished[turn.sessionID] = index
        }
        let nowMs = RecordCoding.milliseconds(now)
        return turns.enumerated().map { index, turn in
            if let request = lookup(turn.sessionID, in: requests) {
                let reopenFinished = (turn.state == .completed || turn.state == .ended)
                    && newestFinished[turn.sessionID] == index
                guard turn.state == .running || turn.state == .waitingForApproval || reopenFinished else { return turn }
                let observedAtMs = max(RecordCoding.milliseconds(request.observedAt), turn.observedAtMs)
                return SessionTurn(provider: turn.provider, sessionID: turn.sessionID, turnID: turn.turnID,
                                   state: .waitingForApproval, startedAtMs: turn.startedAtMs,
                                   observedAtMs: observedAtMs, message: request.message ?? turn.message)
            }
            // Clear the wait without ageing the turn into the quiet-run expiry: answering an ask that sat open
            // for minutes must still read as live work, or the front mark and glow never leave idle.
            guard inboxAuthoritative, turn.provider == "OMP", turn.state == .waitingForApproval else { return turn }
            return SessionTurn(provider: turn.provider, sessionID: turn.sessionID, turnID: turn.turnID,
                               state: .running, startedAtMs: turn.startedAtMs,
                               observedAtMs: max(turn.observedAtMs, nowMs), message: nil)
        }
    }

    private static func lookup(_ sessionID: String, in requests: [String: Event]) -> Event? {
        for key in keys(for: sessionID) {
            if let event = requests[key] { return event }
        }
        return nil
    }

    private static func keys(for sessionID: String) -> [String] {
        if sessionID.hasPrefix("pi:"), sessionID.count > 3 {
            return [sessionID, String(sessionID.dropFirst(3))]
        }
        return [sessionID, "pi:" + sessionID]
    }

    private static func parse(_ data: Data) -> Event? {
        struct Wire: Decodable {
            let sessionID: String
            let message: String?
            let atMs: Int64?
            /// JSON field is still `at`.
            let observedAt: Date?

            enum CodingKeys: String, CodingKey {
                case sessionID, message, atMs
                case observedAt = "at"
            }
        }
        guard let value = try? JSONDecoder().decode(Wire.self, from: data), !value.sessionID.isEmpty else { return nil }
        guard let observedAt = value.observedAt ?? value.atMs.map(RecordCoding.date) else { return nil }
        let message = value.message?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Event(sessionID: value.sessionID,
                     message: message.flatMap { $0.isEmpty ? nil : String($0.prefix(messageLength)) },
                     observedAt: observedAt)
    }
}
