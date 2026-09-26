import AgentHUDSupport
import Foundation

/// A turn that just started waiting for the user — an ask, a tool approval, or an attention hook.
/// Completions and interruptions are news about a turn that ended; this is news about one that stopped for an answer.
public struct SessionAttentionNeed: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let sessionID: String
    public let vendor: String
    public let turnID: String
    public let task: String
    public let message: String?
    public let at: Date

    public init(sessionID: String, vendor: String, turnID: String, task: String, message: String? = nil, at: Date) {
        id = RecordCoding.hash([vendor, sessionID, turnID, "waiting", String(RecordCoding.milliseconds(at))])
        self.sessionID = sessionID
        self.vendor = vendor
        self.turnID = turnID
        self.task = task
        self.message = message.flatMap { $0.isEmpty ? nil : String($0.prefix(2048)) }
        self.at = at
    }
}
