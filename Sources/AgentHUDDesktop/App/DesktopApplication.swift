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
    private var notch: IslandController?
    private var statusItem: StatusItemController?
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
        HotKeyCenter.shared.register(id: 1, keyCode: HotKeyCenter.keyH, modifiers: HotKeyCenter.commandOption) { [weak self] in
            self?.toggleGlow()
        }
        observeChanges({ [weak self] in
            self?.settings.settings.appearance
        }, onChange: { [weak self] in self?.applyAppearance() })
        observeChanges({ [weak self] in
            self?.settings.settings.language
        }, onChange: { [weak self] in
            guard let self else { return }
            self.statusItem?.refreshButton()
            self.notch?.apply(animated: false)
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
            _ = self?.store.report
            _ = self?.settings.agents
            _ = self?.settings.settings.disabledLiveStatusSources
        }, onChange: { [weak self] in self?.checkIslandEvents() })
        store.start()
        if options.openPanel { notch.forceOpen() }
        if store.isAccessAllowed, options.showOnboarding || !settings.hasCompletedOnboarding { showOnboarding() }
        if options.showSettings { showSettings() }
        if options.showStats { showStats() }
    }

    public func stop() { store.stop() }
    public func showSettings(pageID: String? = nil) { settingsWindow.show(pageID: pageID) }
    public func showStats() { statsWindow.show() }
    public func showOnboarding() { onboardingWindow.show() }
    public func toggleGlow() { store.glowHidden.toggle() }

    /// A paused store or a failed refresh leaves the island silent; the baselines wait for the next good report.
    private func checkIslandEvents() {
        guard !store.isPaused, store.lastError == nil, let report = store.report else { return }
        let now = Date()
        let update = islandEvents.update(report: report, agents: settings.agents, now: now, settings: settings.settings)
        for alert in update.quotaAlerts { notch?.present(alert) }
        for completion in update.completions { notch?.present(.completion(completion)) }
        onIslandEvents?(update, report, now)
    }

    private func applyAppearance() {
        switch settings.settings.appearance {
        case .system: NSApp.appearance = nil
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        }
    }
}
