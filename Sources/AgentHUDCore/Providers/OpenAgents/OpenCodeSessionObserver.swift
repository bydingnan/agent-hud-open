import AgentHUDSupport
import Foundation

/// Metadata-only lifecycle snapshots written by the OpenCode V2 Agent HUD plugin.
enum OpenCodeSessionObserver {
    struct Observation: Codable, Sendable {
        let version: Int
        let sessionID: String
        let workspace: String
        let title: String
        let model: String?
        let providerID: String?
        let turnID: String
        let state: SessionTurn.State
        let startedAtMs: Int64
        let observedAtMs: Int64
        let message: String?

        init(version: Int, sessionID: String, workspace: String, title: String, model: String?, providerID: String?,
             turnID: String, state: SessionTurn.State, startedAtMs: Int64, observedAtMs: Int64, message: String? = nil) {
            self.version = version
            self.sessionID = sessionID
            self.workspace = workspace
            self.title = title
            self.model = model
            self.providerID = providerID
            self.turnID = turnID
            self.state = state
            self.startedAtMs = startedAtMs
            self.observedAtMs = observedAtMs
            self.message = message.flatMap { $0.isEmpty ? nil : String($0.prefix(2048)) }
        }

        var turn: SessionTurn {
            .init(provider: "OpenCode", sessionID: sessionID, turnID: turnID, state: state,
                  startedAtMs: startedAtMs, observedAtMs: observedAtMs, message: message)
        }

        var session: OpenAgentSession {
            var value = OpenAgentSession(id: sessionID, client: .opencode, title: title, workspace: workspace,
                path: "", start: RecordCoding.date(startedAtMs), end: RecordCoding.date(observedAtMs), turns: [turn])
            if let model, let providerID { value.setModel(model, provider: providerID) }
            if state == .completed {
                value.completions = [.init(sessionID: sessionID, vendor: "OpenCode", turnID: turnID,
                    task: title, model: model ?? "Unknown", startedAt: RecordCoding.date(startedAtMs),
                    completedAt: RecordCoding.date(observedAtMs))]
            }
            return value
        }
    }

    static func read(_ data: Data, path _: String? = nil) throws -> Observation {
        guard data.count <= 64 * 1024 else { throw ProviderFailure.limit }
        let value = try JSONDecoder().decode(Observation.self, from: data)
        guard value.version == 1, value.sessionID.hasPrefix("opencode:"), value.sessionID.count > 9,
              !value.turnID.isEmpty, value.startedAtMs > 0, value.observedAtMs >= value.startedAtMs else {
            throw ProviderFailure.format
        }
        return value
    }
}
