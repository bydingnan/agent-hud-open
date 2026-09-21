import AppKit
import AgentHUDCore

/// Application menu so ⌘, / ⌘Q / Edit shortcuts work while Agent HUD is frontmost
/// (status-item menus do not provide these key equivalents).
@MainActor
enum AppMainMenu {
    private static let target = Target()

    static func install(openSettings: @escaping () -> Void) {
        target.openSettings = openSettings

        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu(title: AppResources.applicationName)
        let settingsItem = NSMenuItem(
            title: L10n.text("设置…", "Settings…"),
            action: #selector(Target.openSettingsAction),
            keyEquivalent: ","
        )
        settingsItem.target = target
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
        let quitItem = NSMenuItem(
            title: L10n.text("退出 ", "Quit ") + AppResources.applicationName,
            action: #selector(Target.quitAction),
            keyEquivalent: "q"
        )
        quitItem.target = target
        appMenu.addItem(quitItem)
        appItem.submenu = appMenu

        // Without an Edit menu, SecureField / TextField never receive ⌘V / ⌘C / ⌘X.
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: L10n.text("编辑", "Edit"))
        editMenu.addItem(NSMenuItem(title: L10n.text("剪切", "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: L10n.text("拷贝", "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: L10n.text("粘贴", "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: L10n.text("全选", "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = editMenu

        NSApp.mainMenu = mainMenu
    }

    @MainActor
    private final class Target: NSObject {
        var openSettings: () -> Void = {}

        @objc func openSettingsAction() { openSettings() }
        @objc func quitAction() { NSApp.terminate(nil) }
    }
}
