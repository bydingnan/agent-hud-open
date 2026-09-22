import AgentHUDCore

enum AgentTestHelpers {
    static let keyEntryIDs = Set(DefaultAgents.keyEntryPlaceholders.map(\.id))

    static func withoutKeyEntryPlaceholders(_ agents: [AgentDescriptor]) -> [AgentDescriptor] {
        agents.filter { !keyEntryIDs.contains($0.id) }
    }

    static func agentIDsWithoutPlaceholders(_ agents: [AgentDescriptor]) -> [String] {
        withoutKeyEntryPlaceholders(agents).map(\.id)
    }
}
