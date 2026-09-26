import AgentHUDCore
import Foundation
import UserNotifications

/// The standalone application's own notification channel. The island says each event where the screen can see it;
/// a system notification also says it when the user cannot. The core report decides what is new — this only
/// relays, so the island and Notification Center never disagree.
/// Stateless once built, and every UserNotifications entry point is thread-safe, so sharing one instance is safe.
final class SystemNotifier: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = SystemNotifier()
    private override init() { super.init() }

    /// Asks once for permission; macOS keeps the answer, and a denied app posts nothing. An unbundled process
    /// (swift run, a script) has no notification identity, so it stays silent and the island keeps working.
    func prepare() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().delegate = self
        Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
    }

    func present(_ update: IslandEventTracker.Update) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        for completion in update.completions {
            post(title: L10n.text("\(completion.vendor) 本轮已完成", "\(completion.vendor) turn completed"),
                 body: completion.task, id: completion.id)
        }
        for interruption in update.interruptions {
            post(title: L10n.text("\(interruption.vendor) 本轮已中断", "\(interruption.vendor) turn interrupted"),
                 body: interruption.task, id: interruption.id)
        }
        for attention in update.attentionNeeds {
            post(title: L10n.text("\(attention.vendor) 需要你确认", "\(attention.vendor) needs your input"),
                 body: attention.message ?? attention.task, id: attention.id)
        }
    }

    private func post(title: String, body: String, id: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    /// The app is an accessory HUD, but it does own Settings; a banner still shows while its window is frontmost.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
