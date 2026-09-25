import AgentHUDSupport
import Foundation

/// A turn that was in flight and ended without finishing: an interruption, an abort, a failed attempt. It never
/// counts as a completion, and the session's next prompt opens a new turn.
public struct SessionInterruption: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let sessionID: String
    public let vendor: String
    public let turnID: String
    public let task: String
    public let stoppedAt: Date

    public init(sessionID: String, vendor: String, turnID: String, task: String, stoppedAt: Date) {
        id = RecordCoding.hash([vendor, sessionID, turnID, String(RecordCoding.milliseconds(stoppedAt))])
        self.sessionID = sessionID; self.vendor = vendor; self.turnID = turnID
        self.task = task; self.stoppedAt = stoppedAt
    }
}
