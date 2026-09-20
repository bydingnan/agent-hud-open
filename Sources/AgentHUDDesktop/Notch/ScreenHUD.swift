import AppKit
import AgentHUDCore

/// One screen's HUD: its glow window, its island window and its own hover state machine.
///
/// Everything here belongs to a single display, because two displays can be in different modes, be hovered
/// independently and show different things. What is shared — the store, the settings, the system appearance,
/// the pointer — is handed down by `IslandController`, which owns one of these per screen.
@MainActor
final class ScreenHUD {
    /// Height of the open panel; follows the content reported by `IslandRootView`.
    private var panelHeight: CGFloat = IslandController.defaultPanelHeight
    private var alertDetailHeight: CGFloat = 300
    private var expandedSize: CGSize { CGSize(width: IslandController.expandedWidth, height: panelHeight) }

    /// The display this HUD lives on, looked up again each time: `NSScreen` instances are replaced when
    /// displays change, while the key outlives them.
    let key: String
    private let store: UsageStore
    private let settings: SettingsStore
    private(set) var geometry: NotchGeometry
    /// Set by the coordinator, which watches the system appearance once for every screen.
    var systemIsLight = SystemAppearance.isLight
    let glow: GlowWindowController
    let island: IslandWindowController
    private var machine = HoverMachine()
    private var timer: Timer?
    private var shrinkTask: Task<Void, Never>?
    private var targetWindowFrame: CGRect?
    private let alerts = IslandAlertQueue()
    private var activeAlert: IslandAlert? { alerts.current?.alert }
    private var showsAlertDetails: Bool { machine.isOpen && alerts.current?.inUsagePanel == false }
    private var pointerInside = false
    /// Whether the hover currently counts as one that opens the panel; see `reevaluateHover`.
    private var hoverOpens = false
    private var modifierWatch: Timer?

    var onOpenStats: (() -> Void)?
    var onOpenSettings: (() -> Void)?

    init(key: String, screen: NSScreen?, store: UsageStore, settings: SettingsStore) {
        self.key = key
        self.store = store
        self.settings = settings
        // The stored placement decides notch or queue before the first frame, so the HUD never flashes
        // the wrong shape on launch.
        let placement = screen.map { ScreenIdentity.placement(for: $0, in: settings.settings) }
            ?? .default(hasNotch: false)
        let geometry = NotchGeometry.detect(screen: screen, placement: placement)
        self.geometry = geometry
        glow = GlowWindowController(geometry: geometry)
        island = IslandWindowController(frame: geometry.islandFrame, rootView: IslandRootView.placeholder)
        island.onPointerChange = { [weak self] inside in
            self?.pointer(inside: inside)
        }
        alerts.onExpire = { [weak self] in self?.dismissAlert() }

        apply(animated: false)
        island.show()
    }

    // MARK: Hover

    func pointer(inside: Bool) {
        guard pointerInside != inside else { return }
        pointerInside = inside
        alerts.hold(inside)
        // Whether Option is down can change without the pointer moving, so while it is over the HUD the
        // modifier is watched. A global keyboard monitor would ask for accessibility; this does not.
        modifierWatch?.invalidate()
        modifierWatch = nil
        if inside, settings.settings.requiresOptionToOpen {
            modifierWatch = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.reevaluateHover() }
            }
        }
        reevaluateHover()
    }

    /// A collapsed logo queue must not swallow clicks: it sits over the menu bar and whatever window is
    /// under it, and nothing about a row of marks says "target". The panel stops taking mouse events, which
    /// also costs it its tracking, so the pointer is followed with an event monitor instead. An open panel
    /// has buttons and takes its events back.
    private func updateClickThrough(_ passes: Bool) {
        guard island.panel.ignoresMouseEvents != passes else { return }
        island.panel.ignoresMouseEvents = passes
    }

    /// The region that counts as hovering: the marks while collapsed, the panel once it is open. The target
    /// frame rather than the window's, which is briefly grown into a canvas for the opening animation.
    func samplePointer() {
        let region = machine.isOpen ? (targetWindowFrame ?? island.panel.frame) : geometry.rect
        pointer(inside: region.contains(NSEvent.mouseLocation))
    }

    /// Hovering opens the panel, unless the user asked for Option as well.
    private func reevaluateHover() {
        let opens = pointerInside
            && (!settings.settings.requiresOptionToOpen || NSEvent.modifierFlags.contains(.option))
        guard opens != hoverOpens else { return }
        hoverOpens = opens
        let now = Date()
        transition(machine.reduce(opens ? .pointerEntered(at: now) : .pointerExited(at: now), config: config))
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
        if hoverOpens {
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

    /// This HUD's own display, or nothing once it has been unplugged.
    var screen: NSScreen? {
        NSScreen.screens.first { ScreenIdentity.key(for: $0) == key }
    }

    private var placement: ScreenPlacement {
        screen.map { ScreenIdentity.placement(for: $0, in: settings.settings) } ?? .default(hasNotch: false)
    }

    /// The marks this screen shows, one per vendor, in the order the agents are watched in.
    private var queueItems: [LogoQueueItem] {
        LogoQueueItem.queue(rows: store.rows.map { row in
            (vendor: row.agent.vendor,
             isWorking: store.sessions.contains { $0.agentId == row.agent.id && $0.endedAt == nil })
        })
    }

    /// Logo mode sizes the strip from the queue it has to hold.
    private func resolveGeometry() -> NotchGeometry {
        let screen = screen
        let placement = placement
        guard placement.mode == .logos else { return NotchGeometry.detect(screen: screen, placement: placement) }
        let config = LogoQueueConfig(items: queueItems, placement: placement, settings: settings.settings)
        // A queue with nothing in it has no strip to park; the screen falls back to its notch shape.
        guard !config.items.isEmpty else {
            return NotchGeometry.detect(screen: screen, placement: .default(hasNotch: geometry.hasNotch))
        }
        return NotchGeometry.detect(screen: screen, placement: placement, queue: config.size)
    }

    private var logoQueue: LogoQueueConfig? {
        // The geometry still measures the queue when the marks are hidden, so the backdrop keeps the place
        // and the width it had; only the drawing stops.
        guard geometry.mode == .logos, placement.showsLogos else { return nil }
        let config = LogoQueueConfig(items: queueItems, placement: placement, settings: settings.settings)
        return config.items.isEmpty ? nil : config
    }

    /// Takes this HUD's windows off screen; the display it belonged to is gone.
    func close() {
        modifierWatch?.invalidate()
        timer?.invalidate()
        shrinkTask?.cancel()
        island.panel.orderOut(nil)
        glow.panel.orderOut(nil)
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
        // The mode decides the silhouette, not whether there are marks to draw.
        root.hidesSilhouette = geometry.mode == .logos
        if open {
            let height = max(80, min(island.contentHeight(for: root).rounded(), geometry.screenFrame.height - 80))
            if showsAlertDetails { alertDetailHeight = height }
            else { panelHeight = height }
        }
        let expanded = open || activeAlert != nil
        let compactSize = CGSize(width: geometry.rect.width + 2 * (IslandController.alertWingWidth + IslandController.alertSidePadding),
                                 height: max(38, geometry.rect.height))
        let size = open ? (showsAlertDetails ? CGSize(width: IslandController.alertDetailWidth, height: alertDetailHeight) : expandedSize) : compactSize
        // Core frame drives the glow/shadow; the window frame adds the flared top corners.
        let islandFrame = expanded ? geometry.expandedFrame(size: size) : geometry.rect
        let flare = open ? NotchGeometry.expandedTopRadius : NotchGeometry.collapsedTopRadius
        let windowFrame = expanded ? islandFrame.insetBy(dx: -flare, dy: 0) : geometry.islandFrame
        let radius = open ? IslandController.expandedRadius : max(geometry.cornerRadius, activeAlert == nil ? 0 : 14)
        let current = settings.settings
        // This screen's own glow, or the default when it has not been given one.
        let glowSettings = current.glow(on: key)
        // The glow style is the HUD's backdrop in both modes, but the shape it radiates from differs. The
        // notch is a small silhouette, so the field reads as a rim around it. A logo queue wants a curtain
        // exactly as wide as the marks: the shape is a flat lip at the screen's top edge, run wider than the
        // queue so every cell's nearest point is straight above it and the field falls vertically. The glow
        // panel then clips that field back to the queue's own column, cutting off the ends that would dip.
        let backdrop = geometry.mode == .logos && !expanded
        // Only a silhouette is worth rimming. A logo queue has none — its glow is the backdrop behind the
        // marks — so once the panel or an event has grown over the place that field belonged, it stops
        // rather than following the new shape around.
        let drawsGlow = geometry.mode != .logos || backdrop
        let overhang = GlowWindowController.backdropOverhang(glowSettings)
        // The lip is a flat line on the screen's top edge, run wider than the queue: every cell's nearest
        // point is then straight above it, so the field falls vertically instead of curling in at the ends,
        // and the marks sit inside the field rather than below where it starts.
        let glowIsland = backdrop
            ? CGRect(x: geometry.rect.minX - overhang, y: geometry.screenFrame.maxY,
                     width: geometry.rect.width + overhang * 2, height: 2)
            : islandFrame
        let glowRadius = backdrop ? 0 : radius
        let glowGeometry = glowSettings
            .geometry(islandWidth: glowIsland.width, islandHeight: glowIsland.height, islandRadius: glowRadius)
            .fitted(within: geometry.screenFrame.height)
        let appearance = store.glowAppearance(light: systemIsLight, on: key)

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
            outwardOnly: glowSettings.outwardOnly,
            appearance: appearance,
            animated: animated,
            alert: activeAlert,
            quotaVendors: store.rows.filter { $0.level != nil }.map { $0.agent.vendor },
            pattern: glowSettings.pattern(),
            backdrop: backdrop ? geometry.rect : nil,
            drawsGlow: drawsGlow
        )
        // The strip's place on screen is fixed; the window around it is not, so the offset between them is
        // measured rather than assumed to be the window's own top edge — which moves when the panel opens.
        root.logoQueueInset = max(0, windowFrame.maxY - geometry.rect.maxY)
        root.logoQueueHeight = geometry.rect.height
        updateClickThrough(geometry.mode == .logos && !expanded)
        // One source of truth for the pointer while in logo mode: the panel's own tracking disagrees with the
        // coordinator's monitor about the parts of the window the silhouette does not cover, and the two
        // would fight over the state.
        island.onPointerChange = geometry.mode == .logos
            ? nil
            : { [weak self] inside in self?.pointer(inside: inside) }
        root.presentationSize = windowFrame.size
        root.onContentHeight = { [weak self] height in self?.updatePanelHeight(height) }
        island.setRootView(root)
    }
}

