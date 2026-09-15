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

/// Keeps one alert on the island at a time; later alerts wait in arrival order. An alert expires `visibleDuration`
/// after it appears or the pointer last leaves the island, and never while the pointer is over it.
@MainActor
final class IslandAlertQueue {
    struct Presentation {
        let alert: IslandAlert
        /// Whether the user was already reading the usage panel when the alert arrived.
        let inUsagePanel: Bool
    }

    static let visibleDuration: Duration = .seconds(4)

    private(set) var current: Presentation?
    /// Called when the current alert's time is up; the owner dismisses it.
    var onExpire: () -> Void = {}
    private var pending: [IslandAlert] = []
    private var held = false
    private var expiry: Task<Void, Never>?

    /// Shows `alert` now and returns true, or queues it behind the current alert and returns false.
    func show(_ alert: IslandAlert, inUsagePanel: Bool) -> Bool {
        guard current == nil else {
            pending.append(alert)
            return false
        }
        current = Presentation(alert: alert, inUsagePanel: inUsagePanel)
        scheduleExpiry()
        return true
    }

    /// The pointer over the island holds the current alert until it leaves.
    func hold(_ inside: Bool) {
        held = inside
        guard current != nil else { return }
        if inside { expiry?.cancel() } else { scheduleExpiry() }
    }

    /// Removes the current alert and hands back the next one waiting, if any.
    func dismiss() -> IslandAlert? {
        expiry?.cancel()
        current = nil
        return pending.isEmpty ? nil : pending.removeFirst()
    }

    private func scheduleExpiry() {
        expiry?.cancel()
        guard !held else { return }
        expiry = Task { [weak self] in
            do { try await Task.sleep(for: Self.visibleDuration) } catch { return }
            self?.onExpire()
        }
    }
}
