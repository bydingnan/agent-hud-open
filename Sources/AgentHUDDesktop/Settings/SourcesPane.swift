import SwiftUI
import UniformTypeIdentifiers
import AgentHUDCore

struct SourcesPane: View {
    let settings: SettingsStore
    let store: UsageStore
    let theme: Theme
    var sources: [SourceStatus]? = nil
    @State private var expanded: Set<String>
    @State private var dragging: AgentOrderDrag?

    init(settings: SettingsStore, store: UsageStore, theme: Theme, sources: [SourceStatus]? = nil,
         initiallyExpanded: Set<String> = []) {
        self.settings = settings; self.store = store; self.theme = theme; self.sources = sources
        _expanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        let detected = sources ?? SourceDetector.resolve(SourceDetector.detect(), report: store.report)
        let groups = AgentSettingsGroup.make(sources: detected, agents: settings.agents, report: store.report)
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(groups) { group in
                    AgentSettingsCard(group: group, settings: settings, theme: theme,
                        isExpanded: Binding(get: { expanded.contains(group.id) }, set: { value in
                            if value { expanded.insert(group.id) } else { expanded.remove(group.id) }
                        }), dragging: $dragging,
                        onCredentialsSaved: { Task { await store.refreshAccounts() } })
                }
                Text(L10n.text("拖动分组或窗口，调整光晕和面板中的顺序。", "Drag groups or windows to reorder the glow and panel."))
                    .font(.ui(11)).foregroundStyle(theme.secondary).padding(.top, 4)
            }
        }
    }
}

struct AgentSettingsCard: View {
    let group: AgentSettingsGroup
    let settings: SettingsStore
    let theme: Theme
    @Binding var isExpanded: Bool
    @Binding var dragging: AgentOrderDrag?
    var onCredentialsSaved: () -> Void = {}
    private var canExpand: Bool {
        !group.agents.isEmpty || group.hasLiveStatus
            || ["ZenMux", "OpenCode", "Kimi", "GLM"].contains(group.id)
    }
    /// Only vendors with catalog rows (or a key-entry placeholder) have a Show switch that does anything.
    private var canControlDisplay: Bool {
        settings.agents.contains { SettingsStore.matchesDisplayVendor($0, group.id) }
            || DefaultAgents.keyEntryPlaceholder(for: group.id) != nil
            || group.id == "ZenMux"
    }
    var body: some View {
        VStack(spacing: 0) {
            header
            if isExpanded && group.hasLiveStatus {
                SettingsDivider(theme: theme)
                AgentLiveStatusSettings(vendor: group.id, settings: settings)
            }
            if isExpanded && group.id == AdditionalSource.copilot.vendor {
                SettingsDivider(theme: theme)
                CopilotQuotaSettings(settings: settings)
            }
            if isExpanded && group.id == "ZenMux" {
                SettingsDivider(theme: theme)
                ZenMuxKeySettings(theme: theme, onSaved: onCredentialsSaved)
            }
            if isExpanded, let guide = OpenAgentKeyGuide.forVendor(group.id) {
                SettingsDivider(theme: theme)
                OpenAgentKeySettings(guide: guide, theme: theme, onSaved: onCredentialsSaved)
            }
            if isExpanded && !group.agents.isEmpty {
                SettingsDivider(theme: theme)
                ForEach(group.agents) { agent in
                    AgentOrderRow(agent: agent, theme: theme, accountName: group.accountName(for: agent)) { settings.setAgent(id: agent.id, enabled: $0) }
                        .onDrag {
                            dragging = .model(agent.id)
                            return NSItemProvider(object: agent.id as NSString)
                        }
                        .onDrop(of: [UTType.text], delegate: dropDelegate(.model(agent.id)))
                    if agent.id != group.agents.last?.id {
                        SettingsDivider(theme: theme)
                    }
                }
            }
        }
        .background(theme.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.cardBorder, lineWidth: 1))
        // Whole card accepts group drops so reordering works without landing exactly on the handle.
        .onDrop(of: [UTType.text], delegate: dropDelegate(.group(group.id)))
    }

    private var canReorderGroup: Bool {
        // Only groups with at least one saved agent row have an order in SettingsStore.
        group.agents.isEmpty == false
    }

    private var header: some View {
        HStack(spacing: 8) {
            if canReorderGroup {
                OrderDragHandle(theme: theme)
                    .frame(width: 22, alignment: .leading)
                    .padding(.vertical, 18)
                    .contentShape(Rectangle())
                    .onDrag {
                        dragging = .group(group.id)
                        return NSItemProvider(object: group.id as NSString)
                    }
                    .help(L10n.text("拖动以调整分组顺序", "Drag to reorder this group"))
                    .accessibilityLabel(L10n.text("拖动 \(group.id)", "Drag \(group.id)"))
            } else {
                Color.clear.frame(width: 22)
            }
            Button {
                if canExpand {
                    withAnimation(.easeInOut(duration: 0.18)) { isExpanded.toggle() }
                }
            } label: {
                HStack(spacing: 12) {
                    AgentLogo(vendor: group.id, size: 26)
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 7) {
                            Text(group.id).font(.ui(14, .semibold))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if !isExpanded, OpenAgentKeyGuide.forVendor(group.id) != nil || group.id == "ZenMux" {
                            Text(L10n.text("展开以输入 Key 或查看登录引导", "Expand to enter a key or see the login guide"))
                                .font(.ui(10)).foregroundStyle(theme.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(group.plans, id: \.self) { plan in
                            PlanBadge(plan: plan, theme: theme)
                        }
                        ForEach(group.accounts) { account in
                            AccountSummary(account: account, theme: theme)
                        }
                        if !group.apiProviders.isEmpty {
                            Text("API · " + group.apiProviders.joined(separator: ", "))
                                .font(.ui(10)).foregroundStyle(theme.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 4)
                    if !group.agents.isEmpty {
                        Text(L10n.text("显示 \(group.displayedCount)/\(group.agents.count)", "Showing \(group.displayedCount)/\(group.agents.count)"))
                            .font(.tabular(11)).foregroundStyle(theme.secondary)
                            .fixedSize()
                    }
                    if canExpand {
                        Image(systemName: "chevron.right")
                            .font(.ui(10, .semibold)).foregroundStyle(theme.tertiary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .frame(width: 12)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(theme.text)
            .accessibilityIdentifier("agent-group-\(group.id)")
            .accessibilityValue(isExpanded ? L10n.text("已展开", "Expanded") : L10n.text("已折叠", "Collapsed"))
            if canControlDisplay {
                Toggle(L10n.text("显示 \(group.id)", "Show \(group.id)"), isOn: Binding(
                    get: { settings.isVendorDisplayed(group.id) },
                    set: { settings.setVendorDisplayed(group.id, enabled: $0) }
                ))
                .labelsHidden().toggleStyle(.switch).controlSize(.small)
                .accessibilityIdentifier("vendor-display-\(group.id)")
                .help(L10n.text("在光晕和面板中显示此来源", "Show this source on the glow and panel"))
            }
        }
        .padding(.horizontal, 14)
    }

    private func dropDelegate(_ target: AgentOrderDrag) -> ReorderDropDelegate {
        ReorderDropDelegate(target: target, dragging: $dragging, settings: settings)
    }
}

/// One signed-in or previously seen account: its plan badge, name and whether it is the current login.
private struct AccountSummary: View {
    let account: AccountObservation
    let theme: Theme

    var body: some View {
        HStack(spacing: 6) {
            if let plan = account.planLabel {
                PlanBadge(plan: plan, theme: theme)
            }
            Text(account.displayName)
                .font(.ui(11)).foregroundStyle(account.isCurrent ? theme.secondary : theme.tertiary)
                .lineLimit(1).truncationMode(.middle)
            Text(account.statusLabel(now: Date()))
                .font(.ui(10)).foregroundStyle(theme.tertiary)
                .fixedSize()
        }
        .accessibilityElement(children: .combine)
    }
}

private struct AgentLiveStatusSettings: View {
    let vendor: String
    let settings: SettingsStore

    var body: some View {
        SettingRow(label: L10n.text("实时状态", "Live status"),
                   subtitle: L10n.text("显示会话状态与完成提醒", "Show session status and completion reminders")) {
            Toggle(L10n.text("实时状态", "Live status"), isOn: Binding(get: {
                settings.settings.liveStatusEnabled(for: vendor)
            }, set: { value in
                settings.update { $0.setLiveStatus(for: vendor, enabled: value) }
            }))
            .labelsHidden().toggleStyle(.switch).controlSize(.small)
            .accessibilityIdentifier("agent-live-status-\(vendor.lowercased())")
        }
        .padding(.leading, 28)
        .help(L10n.text("历史会话和 Token 统计持续更新。", "Session history and token usage keep updating."))
    }
}

/// Management API key for ZenMux quota. Saved in the Keychain, not in preferences.
private struct ZenMuxKeySettings: View {
    let theme: Theme
    var onSaved: () -> Void = {}
    @State private var draft = ""
    @State private var saved = ZenMuxCredentials.keychainManagementKey() != nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.text("Management API Key", "Management API Key"))
                .font(.ui(12, .semibold))
            SecureField(saved
                ? L10n.text("已保存，输入新 Key 可替换", "Saved — type a new key to replace it")
                : "ZENMUX_MANAGEMENT_API_KEY", text: $draft)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("zenmux-management-key")
            HStack(spacing: 8) {
                Button(L10n.text("保存", "Save")) {
                    ZenMuxCredentials.saveManagementKey(draft)
                    draft = ""
                    saved = ZenMuxCredentials.keychainManagementKey() != nil
                    onSaved()
                }
                .buttonStyle(.bordered)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("zenmux-management-key-save")
                if saved {
                    Button(L10n.text("清除", "Clear")) {
                        ZenMuxCredentials.saveManagementKey(nil)
                        draft = ""
                        saved = false
                        onSaved()
                    }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("zenmux-management-key-clear")
                }
            }
            Text(status)
                .font(.ui(11)).foregroundStyle(theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 42).padding(.vertical, 12)
    }

    private var status: String {
        if saved {
            return L10n.text("已保存在钥匙串，优先于环境变量。", "Saved in the Keychain, and preferred over environment variables.")
        }
        if ZenMuxCredentials.managementKey(saved: nil) != nil {
            return L10n.text("当前使用环境变量或 ~/.config/api-tokens.env。保存后改用这里的 Key。",
                             "Using the environment or ~/.config/api-tokens.env. Saving here replaces that.")
        }
        return L10n.text("粘贴 Management API Key。推理用的 ZENMUX_API_KEY 不能读取额度。",
                         "Paste a Management API Key. The inference key ZENMUX_API_KEY cannot read quota.")
    }
}

private struct OpenAgentKeyGuide {
    let vendor: String
    let title: String
    let loginHint: String
    let slots: [OpenAgentSettingsKeys.Slot]
    let regionLabels: [(OpenAgentSettingsKeys.Slot, String)]

    static func forVendor(_ vendor: String) -> OpenAgentKeyGuide? {
        switch vendor {
        case "OpenCode", "OpenCode Go":
            return .init(
                vendor: "OpenCode",
                title: L10n.text("OpenCode Go API Key", "OpenCode Go API Key"),
                loginHint: L10n.text(
                    "也可在 OpenCode 中登录 opencode-go（写入 auth.json）后自动读取。",
                    "Or sign in to opencode-go inside OpenCode (auth.json) and the HUD will pick it up."),
                slots: [.openCodeGo],
                regionLabels: [])
        case "Kimi":
            return .init(
                vendor: vendor,
                title: L10n.text("Kimi Coding API Key", "Kimi Coding API Key"),
                loginHint: L10n.text(
                    "也可在 Kimi Code、OpenCode 或 Pi 中登录后自动读取。",
                    "Or sign in through Kimi Code, OpenCode or Pi and the HUD will pick it up."),
                slots: [.kimiChina, .kimiGlobal],
                regionLabels: [
                    (.kimiChina, L10n.text("国内", "China")),
                    (.kimiGlobal, L10n.text("国际", "International")),
                ])
        case "GLM":
            return .init(
                vendor: vendor,
                title: L10n.text("GLM Coding Plan API Key", "GLM Coding Plan API Key"),
                loginHint: L10n.text(
                    "也可在 OpenCode、Pi 或 Claude（Z.AI / BigModel coding 端点）中配置后自动读取。",
                    "Or configure OpenCode, Pi or Claude (Z.AI / BigModel coding endpoints) and the HUD will pick it up."),
                slots: [.glmGlobal, .glmChina],
                regionLabels: [
                    (.glmGlobal, L10n.text("国际 Z.AI", "Z.AI Global")),
                    (.glmChina, L10n.text("国内 BigModel", "BigModel China")),
                ])
        default:
            return nil
        }
    }
}

/// Key + login guidance for OpenCode Go / Kimi / GLM. Keys stay in the Keychain.
private struct OpenAgentKeySettings: View {
    let guide: OpenAgentKeyGuide
    let theme: Theme
    var onSaved: () -> Void = {}
    @State private var slot: OpenAgentSettingsKeys.Slot
    @State private var draft = ""
    @State private var saved: Bool

    init(guide: OpenAgentKeyGuide, theme: Theme, onSaved: @escaping () -> Void = {}) {
        self.guide = guide
        self.theme = theme
        self.onSaved = onSaved
        let initial = guide.slots.first { OpenAgentSettingsKeys.load($0) != nil } ?? guide.slots[0]
        _slot = State(initialValue: initial)
        _saved = State(initialValue: OpenAgentSettingsKeys.load(initial) != nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(guide.title).font(.ui(12, .semibold))
            if !guide.regionLabels.isEmpty {
                Picker(L10n.text("区域", "Region"), selection: $slot) {
                    ForEach(guide.regionLabels, id: \.0) { item in
                        Text(item.1).tag(item.0)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .onChange(of: slot) { _, next in
                    draft = ""
                    saved = OpenAgentSettingsKeys.load(next) != nil
                }
            }
            SecureField(saved
                ? L10n.text("已保存，输入新 Key 可替换", "Saved — type a new key to replace it")
                : slot.placeholder, text: $draft)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("openagent-key-\(guide.vendor.lowercased())")
            HStack(spacing: 8) {
                Button(L10n.text("保存", "Save")) {
                    for other in guide.slots where other != slot {
                        OpenAgentSettingsKeys.save(other, nil)
                    }
                    OpenAgentSettingsKeys.save(slot, draft)
                    draft = ""
                    saved = OpenAgentSettingsKeys.load(slot) != nil
                    onSaved()
                }
                .buttonStyle(.bordered)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if saved || guide.slots.contains(where: { OpenAgentSettingsKeys.load($0) != nil }) {
                    Button(L10n.text("清除", "Clear")) {
                        for item in guide.slots { OpenAgentSettingsKeys.save(item, nil) }
                        draft = ""
                        saved = false
                        onSaved()
                    }
                    .buttonStyle(.borderless)
                }
            }
            Text(guide.loginHint)
                .font(.ui(11)).foregroundStyle(theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if saved {
                Text(L10n.text("已保存在钥匙串，将用于读取额度。", "Saved in the Keychain and used to read quota."))
                    .font(.ui(11)).foregroundStyle(theme.secondary)
            }
        }
        .padding(.horizontal, 42).padding(.vertical, 12)
    }
}

/// Quota reading uses the GitHub CLI sign-in, so each time it is switched on the user confirms what is read.
private struct CopilotQuotaSettings: View {
    let settings: SettingsStore
    @State private var confirming = false

    var body: some View {
        SettingRow(label: L10n.text("读取额度", "Read quota"),
                   subtitle: L10n.text("使用 GitHub CLI 的登录查询 Copilot 额度", "Query Copilot quota with the GitHub CLI sign-in")) {
            Toggle(L10n.text("读取额度", "Read quota"), isOn: Binding(get: {
                settings.settings.readCopilotQuota || confirming
            }, set: { value in
                if value { confirming = true } else { settings.update { $0.readCopilotQuota = false } }
            }))
            .labelsHidden().toggleStyle(.switch).controlSize(.small)
            .accessibilityIdentifier("agent-copilot-quota")
        }
        .padding(.leading, 28)
        .alert(L10n.text("读取 GitHub Copilot 额度？", "Read GitHub Copilot quota?"), isPresented: $confirming) {
            Button(L10n.text("取消", "Cancel"), role: .cancel) {}
            Button(L10n.text("同意", "Allow")) { settings.update { $0.readCopilotQuota = true } }
        } message: {
            Text(L10n.text(
                "将读取 GitHub CLI 的登录信息（环境变量 GH_TOKEN 或 GITHUB_TOKEN、macOS 钥匙串中的 gh:github.com、~/.config/gh/hosts.yml），向 api.github.com 查询 Copilot 额度。macOS 可能会请求访问钥匙串。",
                "This reads the GitHub CLI sign-in (the GH_TOKEN or GITHUB_TOKEN environment variable, gh:github.com in the macOS keychain, ~/.config/gh/hosts.yml) to query Copilot quota from api.github.com. macOS may ask for keychain access."))
        }
    }
}
