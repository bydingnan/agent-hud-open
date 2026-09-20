import Foundation

/// Initial rows before clients report their available usage windows.
public enum DefaultAgents {
    public static let list: [AgentDescriptor] = [
        AgentDescriptor(id: "codex", vendor: "Codex", model: "Desktop / CLI", source: L10n.sourceCodexAppServer, enabled: true, connected: false),
        AgentDescriptor(id: "zenmux", vendor: "ZenMux", model: "API", source: L10n.sourceNotConnected, enabled: true, connected: false),
        AgentDescriptor(id: "antigravity", vendor: "Antigravity", model: "Agent", source: L10n.sourceNotConnected, enabled: false, connected: false),
        AgentDescriptor(id: "chatgpt", vendor: "ChatGPT", model: "ChatGPT", source: L10n.sourceBrowserAuth, enabled: false, connected: false),
        AgentDescriptor(id: "claude-session", vendor: "Claude", model: L10n.windowSession, source: L10n.sourceClaudeCode, enabled: false, connected: false),
        AgentDescriptor(id: "copilot", vendor: "GitHub Copilot", model: "Agent", source: L10n.sourceNotConnected, enabled: false, connected: false),
        AgentDescriptor(id: "deepseek", vendor: "DeepSeek", model: "Harness", source: L10n.sourceDeepSeekSessions, enabled: false, connected: false),
    ]
}
