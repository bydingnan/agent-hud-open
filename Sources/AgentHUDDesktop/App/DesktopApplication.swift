import AppKit
import AgentHUDCore

/// Owns the local desktop presentation and observes the supplied usage store.
@MainActor
public final class DesktopApplication {
    public let settings: SettingsStore
    public let store: UsageStore
    private let options: DesktopLaunchOptions
    private let additionalSettingsPages: [DesktopSettingsPage]
    private let onIslandEvents: ((IslandEventTracker.Update, UsageReport, Date) -> Void)?
    private var islandEvents = IslandEventTracker()
    /// The requests already on the island, so a change to the waiting list says which ones arrived and which left.
    private var shownRequests: [String] = []
    /// Asks / attention waits already on the island, keyed like `IslandAlert.attention` so a wait that cleared in
    /// the client is taken off without being answered here.
    private var shownAttentions: [SessionAttentionNeed] = []
    private var notch: IslandController?
    private var statusItem: StatusItemController?
    private var keyMonitor: Any?
    private lazy var settingsWindow = SettingsWindowController(
        settings: settings, store: store, additionalPages: additionalSettingsPages
    )
    private lazy var statsWindow = StatsWindowController(store: store)
    private let onboardingWindow: OnboardingWindowController

    /// `onIslandEvents` receives every island event check after the island has presented it, including checks that
    /// found nothing, with the report and time the check used.
    public init(options: DesktopLaunchOptions, settings: SettingsStore, store: UsageStore,
                additionalSettingsPages: [DesktopSettingsPage] = [],
                onIslandEvents: ((IslandEventTracker.Update, UsageReport, Date) -> Void)? = nil) {
        self.options = options
        self.settings = settings
        self.store = store
        self.additionalSettingsPages = additionalSettingsPages
        self.onIslandEvents = onIslandEvents
        onboardingWindow = OnboardingWindowController(settings: settings, store: store,
            sources: options.demo ? { DemoData.sources } : { SourceDetector.detect() })
        onboardingWindow.onFinish = { [weak self] in
            guard let self else { return }
            self.settings.markOnboardingComplete()
            Task { await self.store.refresh() }
        }
    }

    public func start() {
        applyAppearance()
        installIslandAndMenu()
        installObservers()
        // Seeded after the island is listening, so the demo's requests arrive the way a client's would.
        if options.demo { PermissionRequests.shared.seedDemo() } else { PermissionRequests.shared.start() }
        store.start()
        if options.openPanel { notch?.forceOpen() }
        // First-launch source list is unused for day-to-day; only --show-onboarding opens it.
        if options.showOnboarding {
            showOnboarding()
        } else if !settings.hasCompletedOnboarding {
            settings.markOnboardingComplete()
        }
        if options.showSettings { showSettings() }
        if options.showStats { showStats() }
    }

    private func installIslandAndMenu() {
        let notch = IslandController(store: store, settings: settings)
        notch.onOpenStats = { [weak self] in self?.showStats() }
        notch.onOpenSettings = { [weak self] in self?.showSettings() }
        self.notch = notch
        let statusItem = StatusItemController(store: store, settings: settings)
        statusItem.actions = MenuActions(
            toggleGlow: { [weak self] in self?.toggleGlow() },
            openSettings: { [weak self] in self?.showSettings() },
            openStats: { [weak self] in self?.showStats() },
            quit: { NSApp.terminate(nil) }
        )
        self.statusItem = statusItem
        HostedWindowActivation.restorePolicy = { [weak self] closing in
            self?.applyDockVisibility(excluding: closing)
        }
        HostedWindowActivation.setDockVisible = { [weak self] visible in self?.setDockVisible(visible) }
        AppMainMenu.install(openSettings: { [weak self] in self?.showSettings() })
        HotKeyCenter.shared.register(
            id: 1, keyCode: HotKeyCenter.keyH, modifiers: HotKeyCenter.commandOption
        ) { [weak self] in
            self?.toggleGlow()
        }
        installForegroundShortcuts()
    }

    private func installObservers() {
        observeChanges({ [weak self] in
            self?.settings.settings.appearance
        }, onChange: { [weak self] in self?.applyAppearance() })
        observeChanges({ [weak self] in
            self?.settings.settings.language
        }, onChange: { [weak self] in
            guard let self else { return }
            self.statusItem?.refreshButton()
            self.notch?.apply(animated: false)
            AppMainMenu.install(openSettings: { [weak self] in self?.showSettings() })
            Task { await self.store.refresh() }
        })
        observeChanges({ [weak self] in
            _ = self?.store.lastError
        }, onChange: { [weak self] in
            if let error = self?.store.lastError { NSLog("[AgentHUD] refresh failed: %@", error) }
        })
        observeChanges({ [weak self] in
            self?.settings.settings.launchAtLogin
        }, onChange: { [weak self] in
            guard let self else { return }
            LoginItem.set(self.settings.settings.launchAtLogin)
        })
        observeChanges({ [weak self] in
            self?.settings.settings.showInDock
        }, onChange: { [weak self] in self?.applyDockVisibility() })
        applyDockVisibility()
        observeChanges({ [weak self] in
            _ = self?.store.report
            _ = self?.settings.agents
            _ = self?.settings.settings.disabledLiveStatusSources
        }, onChange: { [weak self] in self?.checkIslandEvents() })
        // The channel is open whenever the app is: a client that asks while it is closed keeps its own prompt.
        observeChanges({ PermissionRequests.shared.pending.map(\.id) },
                       onChange: { [weak self] in self?.syncPermissionRequests() })
    }

    public func stop() {
        // Quitting must never leave a client waiting on an answer that is no longer coming.
        PermissionRequests.shared.stop()
        store.stop()
        HostedWindowActivation.restorePolicy = nil
        HostedWindowActivation.setDockVisible = nil
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    /// Mirrors the requests waiting for the user onto the island: a new one is shown, and one the client took back
    /// disappears without being answered.
    private func syncPermissionRequests() {
        let pending = PermissionRequests.shared.pending
        let ids = pending.map(\.id)
        for id in shownRequests where !ids.contains(id) { notch?.withdraw(requestID: id) }
        for request in pending where !shownRequests.contains(request.id) { notch?.present(.permission(request)) }
        shownRequests = ids
        // A request that only joined or left the queue changes no card, but it does change how many are waiting.
        notch?.apply(animated: true)
    }
    public func showSettings(pageID: String? = nil) {
        // Settings and the expanded island compete for attention; collapse first.
        notch?.forceCollapse()
        settingsWindow.show(pageID: pageID)
    }
    public func showStats() {
        Task { await store.refreshAccounts() }
        statsWindow.show()
    }
    public func showOnboarding() { onboardingWindow.show() }
    public func toggleGlow() { store.glowHidden.toggle() }

    /// A paused store or a failed refresh leaves the island silent; the baselines wait for the next good report.
    private func checkIslandEvents() {
        guard !store.isPaused, store.lastError == nil, let report = store.report else { return }
        let now = Date()
        let update = islandEvents.update(report: report, agents: settings.agents, now: now, settings: settings.settings)
        for alert in update.quotaAlerts { notch?.present(alert) }
        for grant in update.resetCreditGrants { notch?.present(.resetCredits(grant)) }
        for completion in update.completions { notch?.present(.completion(completion)) }
        for attention in update.attentionNeeds {
            notch?.present(.attention(attention))
            if !shownAttentions.contains(where: { $0.id == attention.id }) {
                shownAttentions.append(attention)
            }
        }
        syncAttentionAlerts(report: report)
        onIslandEvents?(update, report, now)
    }

    /// An ask holds the island until the client stops waiting. The tracker only names the moment a wait opens, so
    /// each refresh compares the ones still on screen to the turns that are still waiting and withdraws the rest.
    private func syncAttentionAlerts(report: UsageReport) {
        let waitingSessions = Set(report.turns.filter { $0.state == .waitingForApproval }.map(\.sessionID))
        shownAttentions.removeAll { need in
            guard waitingSessions.contains(need.sessionID) else {
                notch?.withdraw(requestID: need.id)
                return true
            }
            return false
        }
    }

    private func applyAppearance() {
        switch settings.settings.appearance {
        case .system: NSApp.appearance = nil
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        }
    }

    private func applyDockVisibility(excluding closing: NSWindow? = nil) {
        let hostedOpen = NSApp.windows.contains {
            guard $0 !== closing else { return false }
            return $0.windowController is HostedWindowController && ($0.isVisible || $0.isMiniaturized)
        }
        setDockVisible(settings.settings.showInDock || hostedOpen)
    }

    /// AppKit often keeps a Dock icon after `.regular` → `.accessory` while we stay active.
    /// Hopping through `.prohibited` forces the icon off for menu-bar-only mode.
    private func setDockVisible(_ visible: Bool) {
        let wanted: NSApplication.ActivationPolicy = visible ? .regular : .accessory
        guard NSApp.activationPolicy() != wanted else { return }
        if !visible {
            NSApp.setActivationPolicy(.prohibited)
        }
        NSApp.setActivationPolicy(wanted)
    }

    /// ⌘, opens Settings while this app is frontmost (has a key window). Status-item menu
    /// equivalents only fire when that menu is open; this covers the settings/stats windows.
    private func installForegroundShortcuts() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags == .command, event.charactersIgnoringModifiers == "," else { return event }
            self?.showSettings()
            return nil
        }
    }
}
