import AppKit
import AgentHUDCore

/// Names a display so its HUD placement survives unplugging, sleeping and renumbering.
///
/// `NSScreen`'s display ID is reassigned when displays come and go, so it cannot key stored settings.
/// The display's UUID is stable for the same physical panel; a display that has none at all (rare, and
/// possible for virtual displays) falls back to its ID, which at least holds for the current session.
enum ScreenIdentity {
    static func key(for screen: NSScreen) -> String {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return "screen:unknown"
        }
        let id = CGDirectDisplayID(number.uint32Value)
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return "display:\(id)" }
        return CFUUIDCreateString(nil, uuid) as String
    }

    static func name(for screen: NSScreen) -> String {
        let name = screen.localizedName
        return name.isEmpty ? L10n.text("显示器", "Display") : name
    }

    static func hasNotch(_ screen: NSScreen) -> Bool { screen.safeAreaInsets.top > 0 }

    /// The stored placement for a screen, or the default its hardware deserves.
    static func placement(for screen: NSScreen, in settings: AgentHUDCore.Settings) -> ScreenPlacement {
        settings.screens[key(for: screen)] ?? .default(hasNotch: hasNotch(screen))
    }

    /// The screen the pointer is on, which is the one alerts belong on.
    static func underPointer(_ screens: [NSScreen] = NSScreen.screens) -> NSScreen? {
        let point = NSEvent.mouseLocation
        return screens.first { $0.frame.contains(point) } ?? screens.first
    }
}
