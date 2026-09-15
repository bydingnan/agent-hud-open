import AgentHUDCore

/// One presentation queue for quota events and completed turns.
enum IslandAlert: Identifiable {
    case quota(QuotaAlert)
    case completion(SessionCompletion)

    var id: String {
        switch self {
        case .quota(let event): return event.id.uuidString
        case .completion(let event): return event.id
        }
    }
    var vendor: String {
        switch self {
        case .quota(let event): return event.agent.vendor
        case .completion(let event): return event.vendor
        }
    }
    var isWarning: Bool {
        if case .quota(let event) = self { return event.kind == .exhaustion }
        return false
    }
    var accent: RGBA { RGBA(hex: isWarning ? 0xe9a16d : 0x6cd8ac) }
}
