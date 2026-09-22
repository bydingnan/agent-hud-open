import AppKit
import SwiftUI

/// Standard windows with a transparent title bar so the SwiftUI content owns the whole surface
/// (traffic lights stay native and sit over our sidebar/header, as in the design).
@MainActor
enum WindowFactory {
    static func make(size: CGSize, title: String, resizable: Bool = false) -> NSWindow {
        var mask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        if resizable { mask.insert(.resizable) }
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: mask, backing: .buffered, defer: false)
        window.title = title
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.standardWindowButton(.zoomButton)?.isEnabled = resizable
        window.center()
        return window
    }
}

/// Lets `DesktopApplication` restore Dock / accessory policy when the last hosted window closes.
enum HostedWindowActivation {
    /// Called with the closing window so it can be excluded from the still-open check.
    @MainActor static var restorePolicy: ((NSWindow?) -> Void)?
    /// Force `.regular` while a hosted window is opening (avoids scanning NSApp.windows).
    @MainActor static var setDockVisible: ((Bool) -> Void)?
}

/// Hosts one SwiftUI root view in a factory window. Subclasses pass the view to `setContent` after initialisation, so
/// it can call back into the controller.
class HostedWindowController: NSWindowController, NSWindowDelegate {
    private let hosting = NSHostingView(rootView: AnyView(EmptyView()))
    private let baseSize: CGSize

    init(size: CGSize, title: String, resizable: Bool = false) {
        let window = WindowFactory.make(size: size, title: title, resizable: resizable)
        baseSize = size
        hosting.sizingOptions = []
        hosting.frame = CGRect(origin: .zero, size: window.contentLayoutRect.size)
        hosting.autoresizingMask = [.width, .height]
        window.contentView = hosting
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Replaces the root view; with `fitToContent` the window grows to the view's ideal height.
    func setContent<Content: View>(_ content: Content, fitToContent: Bool = false) {
        hosting.rootView = AnyView(content.ignoresSafeArea())
        guard fitToContent, let window else { return }
        hosting.sizingOptions = [.intrinsicContentSize]
        let fitting = hosting.fittingSize
        hosting.sizingOptions = []
        if fitting.height > 0 {
            window.setContentSize(CGSize(width: baseSize.width, height: max(baseSize.height, fitting.height)))
        }
    }

    func show() {
        // Become a normal app only while a hosted window is open, then order front once.
        // Do not re-activate on every click — that steals focus from SecureField paste / typing.
        HostedWindowActivation.setDockVisible?(true)
        guard let window else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        // A closed window (isReleasedWhenClosed = false) must be shown again; already-open
        // windows just come to the front on the active Space.
        if !window.isVisible {
            window.center()
            showWindow(nil)
        }
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        // Exclude this window: it is still isVisible here, and with isReleasedWhenClosed = false
        // it can linger in NSApp.windows after close. Minimized others keep the Dock.
        HostedWindowActivation.restorePolicy?(window)
    }
}
