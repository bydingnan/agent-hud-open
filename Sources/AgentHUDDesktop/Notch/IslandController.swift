import AppKit
import AgentHUDCore

/// Coordinates the glow window, the island window and the hover state machine.
@MainActor
final class IslandController {
    static let expandedWidth: CGFloat = 540
    static let defaultPanelHeight: CGFloat = 326
    static let expandedRadius: CGFloat = 26
    static let alertWingWidth: CGFloat = 112
    static let alertSidePadding: CGFloat = 16
    static let alertDetailWidth: CGFloat = 400

    /// Height of the open panel; follows the content reported by `IslandRootView`.
    private var panelHeight: CGFloat = IslandController.defaultPanelHeight
    private var alertDetailHeight: CGFloat = 300
    private var expandedSize: CGSize { CGSize(width: Self.expandedWidth, height: panelHeight) }

    private let store: UsageStore
    private let settings: SettingsStore
    private(set) var geometry: NotchGeometry
    let glow: GlowWindowController
    let island: IslandWindowController
    private var machine = HoverMachine()
    private var timer: Timer?
    private var shrinkTask: Task<Void, Never>?
    private var targetWindowFrame: CGRect?
    private var systemIsLight = SystemAppearance.isLight
    private var observers: [Any] = []
    private let alerts = IslandAlertQueue()
    private var activeAlert: IslandAlert? { alerts.current?.alert }
    private var showsAlertDetails: Bool { machine.isOpen && alerts.current?.inUsagePanel == false }
    private var pointerInside = false

    var onOpenStats: (() -> Void)?
    var onOpenSettings: (() -> Void)?

    init(store: UsageStore, settings: SettingsStore) {
        self.store = store
        self.settings = settings
        // The stored placement decides notch or queue before the first frame, so the HUD never flashes
        // the wrong shape on launch.
        let geometry = NotchGeometry.detect(placement: NSScreen.main.map { ScreenIdentity.placement(for: $0, in: settings.settings) })
        self.geometry = geometry
        glow = GlowWindowController(geometry: geometry)
        island = IslandWindowController(frame: geometry.islandFrame, rootView: IslandRootView.placeholder)
        island.onPointerChange = { [weak self] inside in
            self?.pointer(inside: inside)
        }
        alerts.onExpire = { [weak self] in self?.dismissAlert() }
        NSLog("[AgentHUD] notch=%@ rect=%@", geometry.hasNotch ? "yes" : "no", NSStringFromRect(geometry.rect))

        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.relayout() }
        })
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.systemIsLight = SystemAppearance.isLight
                self?.apply(animated: false)
            }
        })
        observeChanges({ [weak self] in self?.inputs }, onChange: { [weak self] in
            self?.apply(animated: true)
        })

        apply(animated: false)
        island.show()
    }

    /// What the island's frame and glow are computed from. Pause expiry and session liveness read the store's clock,
    /// which ticks every ten seconds, so the values are compared and a tick that changes none of them leaves the island
    /// alone; the panel's countdowns observe the clock themselves.
    private struct Inputs: Equatable {
        let rows: [AgentRow]
        let sessions: [LiveSession]
        let isPaused: Bool
        let glowHidden: Bool
        let appearance: GlowAppearance
        let settings: AgentHUDCore.Settings
        let agents: [AgentDescriptor]
    }

    private var inputs: Inputs {
        Inputs(rows: store.rows, sessions: store.sessions, isPaused: store.isPaused, glowHidden: store.glowHidden,
               appearance: store.glowAppearance(light: systemIsLight), settings: settings.settings, agents: settings.agents)
    }

    // MARK: Hover

    func pointer(inside: Bool) {
        pointerInside = inside
        alerts.hold(inside)
        let now = Date()
        let event: HoverMachine.Event = inside ? .pointerEntered(at: now) : .pointerExited(at: now)
        transition(machine.reduce(event, config: config))
    }

    func forceOpen() {
        transition(machine.reduce(.forceOpen, config: config))
    }

    func forceCollapse() {
        transition(machine.reduce(.forceCollapse, config: config))
    }

    // MARK: Quota events

    func present(_ alert: QuotaAlert) { present(.quota(alert)) }

    func present(_ alert: IslandAlert) {
        guard !store.glowHidden, !store.isPaused, alerts.show(alert, inUsagePanel: machine.isOpen) else { return }
        // An event owns the brief expansion; a pending hover must not open the full panel underneath it.
        timer?.invalidate()
        timer = nil
        if !machine.isOpen { machine = HoverMachine() }
        if pointerInside {
            transition(machine.reduce(.pointerEntered(at: Date()), config: config))
        }
        apply(animated: true)
        island.show()
    }

    private func dismissAlert() {
        if let next = alerts.dismiss() {
            present(next)
        } else {
            if !pointerInside { machine = HoverMachine() }
            apply(animated: true)
        }
    }

    private func openAlert() {
        guard let alert = activeAlert else { return }
        if case .quota(let event) = alert, store.rows.contains(where: { $0.id == event.agent.id }) {
            store.selectedQuotaId = event.agent.id
        }
        dismissAlert()
        onOpenStats?()
    }

    private var config: HoverMachine.Config {
        HoverMachine.Config(hoverDelay: settings.settings.hoverDelay, collapseDelay: settings.settings.collapseDelay)
    }

    private func transition(_ transition: HoverMachine.Transition) {
        let wasOpen = machine.isOpen
        machine = transition.machine
        timer?.invalidate()
        timer = nil
        if let deadline = transition.deadline {
            let interval = max(0.001, deadline.timeIntervalSinceNow)
            timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.timerFired() }
            }
        }
        if wasOpen != machine.isOpen {
            // The panel opening is someone looking at the numbers, which is reason enough to read the accounts again.
            if machine.isOpen { Task { await store.refreshAccounts() } }
            apply(animated: true)
        }
    }

    private func timerFired() {
        transition(machine.reduce(.timerFired(at: Date()), config: config))
    }

    // MARK: Layout

    /// Resizes the open panel to its content (rows come and go as windows are discovered).
    private func updatePanelHeight(_ height: CGFloat) {
        let clamped = max(80, min(height.rounded(), geometry.screenFrame.height - 80))
        if showsAlertDetails {
            guard abs(clamped - alertDetailHeight) >= 1 else { return }
            alertDetailHeight = clamped
            apply(animated: true)
            return
        }
        guard clamped > 0, abs(clamped - panelHeight) >= 1 else { return }
        panelHeight = clamped
        if machine.isOpen { apply(animated: true) }
    }

    func relayout() {
        apply(animated: false)
    }

    /// The screen the HUD lives on, and how that screen is set to present it. Still one screen; the queue's
    /// size feeds back into the geometry, so the strip is exactly as wide as the marks it holds.
    private var hudScreen: NSScreen? {
        NSScreen.screens.first(where: { ScreenIdentity.hasNotch($0) }) ?? NSScreen.main ?? NSScreen.screens.first
    }

    private var placement: ScreenPlacement {
        hudScreen.map { ScreenIdentity.placement(for: $0, in: settings.settings) }
            ?? .default(hasNotch: false)
    }

    /// The marks this screen shows, one per vendor, in the order the agents are watched in.
    private var queueItems: [LogoQueueItem] {
        LogoQueueItem.queue(rows: store.rows.map { row in
            (vendor: row.agent.vendor,
             isWorking: store.sessions.contains { $0.agentId == row.agent.id && $0.endedAt == nil })
        })
    }

    /// Logo mode needs the queue's size to size the strip, and the queue needs the menu bar height to size
    /// its marks, so the screen is measured once before the strip is laid out.
    private func resolveGeometry() -> NotchGeometry {
        let placement = placement
        guard placement.mode == .logos else { return NotchGeometry.detect(placement: placement) }
        let menuBar = NotchGeometry.detect().menuBarHeight
        let config = LogoQueueConfig(items: queueItems, placement: placement,
                                     settings: settings.settings, menuBarHeight: menuBar)
        guard !config.items.isEmpty else { return NotchGeometry.detect(placement: .default(hasNotch: geometry.hasNotch)) }
        return NotchGeometry.detect(placement: placement, queue: config.size)
    }

    private var logoQueue: LogoQueueConfig? {
        guard geometry.mode == .logos else { return nil }
        let config = LogoQueueConfig(items: queueItems, placement: placement,
                                     settings: settings.settings, menuBarHeight: geometry.menuBarHeight)
        return config.items.isEmpty ? nil : config
    }

    func apply(animated: Bool) {
        let open = machine.isOpen
        geometry = resolveGeometry()
        let animated = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        var root = IslandRootView(
            store: store,
            isOpen: open,
            collapsedSize: geometry.islandFrame.size,
            collapsedTopRadius: NotchGeometry.collapsedTopRadius,
            collapsedBottomRadius: geometry.cornerRadius,
            lightBorder: systemIsLight,
            onOpenStats: { [weak self] in self?.onOpenStats?() },
            onOpenSettings: { [weak self] in self?.onOpenSettings?() },
            alert: activeAlert,
            onOpenAlert: { [weak self] in self?.openAlert() },
            showsAlertDetails: showsAlertDetails,
            animatesGeometry: animated
        )
        root.logoQueue = logoQueue
        if open {
            let height = max(80, min(island.contentHeight(for: root).rounded(), geometry.screenFrame.height - 80))
            if showsAlertDetails { alertDetailHeight = height }
            else { panelHeight = height }
        }
        let expanded = open || activeAlert != nil
        let compactSize = CGSize(width: geometry.rect.width + 2 * (Self.alertWingWidth + Self.alertSidePadding),
                                 height: max(38, geometry.rect.height))
        let size = open ? (showsAlertDetails ? CGSize(width: Self.alertDetailWidth, height: alertDetailHeight) : expandedSize) : compactSize
        // Core frame drives the glow/shadow; the window frame adds the flared top corners.
        let islandFrame = expanded ? geometry.expandedFrame(size: size) : geometry.rect
        let flare = open ? NotchGeometry.expandedTopRadius : NotchGeometry.collapsedTopRadius
        let windowFrame = expanded ? islandFrame.insetBy(dx: -flare, dy: 0) : geometry.islandFrame
        let radius = open ? Self.expandedRadius : max(geometry.cornerRadius, activeAlert == nil ? 0 : 14)
        let current = settings.settings
        // The glow style is the HUD's backdrop in both modes, but the shape it radiates from differs. The
        // notch is a small silhouette, so the field reads as a rim around it. A logo queue wants a curtain
        // exactly as wide as the marks: the shape is a flat lip at the screen's top edge, run wider than the
        // queue so every cell's nearest point is straight above it and the field falls vertically. The glow
        // panel then clips that field back to the queue's own column, cutting off the ends that would dip.
        let backdrop = geometry.mode == .logos && !expanded
        let overhang = current.glowRange + current.glowBlur * 3 + NotchGeometry.fallbackWidth
        // The lip's bottom edge sits on the marks' centre line, not the screen's top edge: the field fades
        // with distance from that edge, so anchoring it to the screen would leave a tall queue hanging in
        // the faint tail of its own backdrop.
        let glowIsland = backdrop
            ? CGRect(x: geometry.rect.minX - overhang, y: islandFrame.midY,
                     width: geometry.rect.width + overhang * 2,
                     height: geometry.screenFrame.maxY - islandFrame.midY + overhang)
            : islandFrame
        let glowRadius = backdrop ? 0 : radius
        let glowGeometry = current.glowGeometry(islandWidth: glowIsland.width, islandHeight: glowIsland.height, islandRadius: glowRadius)
        let appearance = store.glowAppearance(light: systemIsLight)

        if !animated || targetWindowFrame != windowFrame {
            shrinkTask?.cancel()
            targetWindowFrame = windowFrame
            if animated {
                // Keep a canvas large enough for both shapes while the sides and bottom move independently.
                let width = max(island.panel.frame.width, windowFrame.width)
                let height = max(island.panel.frame.height, windowFrame.height)
                island.setFrame(CGRect(x: geometry.centerX - width / 2, y: geometry.top - height, width: width, height: height))
                island.setVisibleSize(windowFrame.size)
                shrinkTask = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(IslandAnimation.duration)) } catch { return }
                    self?.island.setFrame(windowFrame)
                    self?.shrinkTask = nil
                }
            } else {
                shrinkTask = nil
                island.setFrame(windowFrame)
                island.setVisibleSize(windowFrame.size)
            }
        }
        // Render changed bitmaps before starting SwiftUI; expensive blur work must not consume animation frames.
        glow.update(
            geometry: geometry,
            island: glowIsland,
            islandRadius: glowRadius,
            glow: glowGeometry,
            outwardOnly: current.glowOutwardOnly,
            appearance: appearance,
            animated: animated,
            alert: activeAlert,
            quotaVendors: store.rows.filter { $0.level != nil }.map { $0.agent.vendor },
            pattern: current.glowPattern()
        )
        root.presentationSize = windowFrame.size
        root.onContentHeight = { [weak self] height in self?.updatePanelHeight(height) }
        island.setRootView(root)
    }
}

enum SystemAppearance {
    /// The menu bar follows the system setting even when the app forces its own appearance.
    static var isLight: Bool {
        UserDefaults.standard.string(forKey: "AppleInterfaceStyle")?.lowercased() != "dark"
    }
}
