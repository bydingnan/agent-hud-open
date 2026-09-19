import SwiftUI
import AgentHUDCore

/// One mark in the queue. The queue shows one mark per vendor, not per agent: two Claude windows are
/// one Claude, and the mark bobs when any of them is working.
struct LogoQueueItem: Identifiable, Equatable {
    let vendor: String
    /// Any agent of this vendor has a running session: the mark bobs at the working period, not the idle one.
    let isWorking: Bool
    var id: String { vendor }

    /// Collapses agents onto their vendors, keeping the order they were watched in.
    static func queue(rows: [(vendor: String, isWorking: Bool)]) -> [LogoQueueItem] {
        var order: [String] = []
        var working: [String: Bool] = [:]
        for row in rows {
            if working[row.vendor] == nil { order.append(row.vendor) }
            working[row.vendor] = (working[row.vendor] ?? false) || row.isWorking
        }
        return order.map { LogoQueueItem(vendor: $0, isWorking: working[$0] ?? false) }
    }
}

/// A queue resolved for one screen: what to draw, how big, and how fast.
struct LogoQueueConfig: Equatable {
    var items: [LogoQueueItem]
    var edge: HUDEdge
    /// Side of one mark, in points.
    var logo: CGFloat
    var gap: CGFloat
    var workingSeconds: Double
    var idleSeconds: Double

    init(items: [LogoQueueItem], placement: ScreenPlacement, settings: AgentHUDCore.Settings) {
        self.items = items
        edge = placement.edge
        logo = placement.logoSize
        gap = logo * placement.gapScale
        workingSeconds = settings.breathSeconds
        idleSeconds = settings.idleBreathSeconds
    }

    /// What the marks occupy.
    var size: CGSize {
        guard !items.isEmpty else { return .zero }
        let run = logo * CGFloat(items.count) + gap * CGFloat(items.count - 1)
        return edge.isHorizontal ? CGSize(width: run, height: logo) : CGSize(width: logo, height: run)
    }
}

/// The collapsed HUD on a screen in logo mode: every watched agent's own mark, bobbing in place. Working
/// agents bob at the working period and resting ones at the idle one, so a glance says which agent is busy.
/// The marks keep their own artwork; status colour is carried by the glow behind them, not by the logos.
///
/// The marks are plain layers holding baked bitmaps, animated by Core Animation. Driving the bob from
/// SwiftUI instead re-evaluates every mark on the main thread each frame, which on a full queue costs more
/// than the glow it sits on.
struct LogoQueueView: NSViewRepresentable {
    let config: LogoQueueConfig
    let light: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale

    func makeNSView(context: Context) -> LogoQueueLayerView { LogoQueueLayerView() }

    func updateNSView(_ view: LogoQueueLayerView, context: Context) {
        view.apply(config: config, light: light, scale: displayScale, animates: !reduceMotion)
    }
}

/// Lays the marks out along the edge and gives each one a repeating offset animation.
final class LogoQueueLayerView: NSView {
    /// How far a mark travels, as a share of its side, and the stagger that turns a row of bobs into a wave.
    private static let travel: CGFloat = 0.14
    private static let stagger = 0.13

    private var marks: [CALayer] = []
    private var applied: (config: LogoQueueConfig, light: Bool, scale: CGFloat, animates: Bool)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        guard let applied else { return }
        position(config: applied.config)
    }

    /// The marks are laid out against the view's own bounds, so a size change has to reach them even when
    /// AppKit does not consider the bounds themselves changed.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if let applied { position(config: applied.config) }
    }

    func apply(config: LogoQueueConfig, light: Bool, scale: CGFloat, animates: Bool) {
        if let applied, applied.config == config, applied.light == light,
           applied.scale == scale, applied.animates == animates { return }
        let rebuild = applied?.config.items.map(\.id) != config.items.map(\.id)
            || applied?.light != light || applied?.scale != scale
            || applied?.config.logo != config.logo
        applied = (config, light, scale, animates)
        if rebuild { build(config: config, light: light, scale: scale) }
        position(config: config)
        animate(config: config, animates: animates)
    }

    private func build(config: LogoQueueConfig, light: Bool, scale: CGFloat) {
        marks.forEach { $0.removeFromSuperlayer() }
        let side = Int((config.logo * scale).rounded())
        let outline = Int(max(1, (config.logo * 0.03 * scale).rounded()))
        // The queue sits on the wallpaper: the dark artwork variant is the one that reads there.
        marks = config.items.map { item in
            let mark = CALayer()
            mark.contentsScale = scale
            mark.contentsGravity = .resizeAspect
            mark.contents = LogoImages.image(LogoImages.Key(vendor: item.vendor, side: side,
                                                            outline: outline, light: false))
            layer?.addSublayer(mark)
            return mark
        }
    }

    private func position(config: LogoQueueConfig) {
        // The baked outline overflows the mark on every edge, so each layer is grown by it and the extra
        // is centred away; the spacing the user set still applies to the marks themselves.
        let bleed = max(1, config.logo * 0.03)
        let step = config.logo + config.gap
        // The view is given the window's width, which is wider than the run; the queue sits in the middle
        // of it, as the notch does.
        let run = config.edge.isHorizontal ? config.size.width : config.size.height
        let lead = max(0, ((config.edge.isHorizontal ? bounds.width : bounds.height) - run) / 2)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, mark) in marks.enumerated() {
            let along = lead + CGFloat(index) * step
            let origin = config.edge.isHorizontal
                ? CGPoint(x: along, y: (bounds.height - config.logo) / 2)
                : CGPoint(x: (bounds.width - config.logo) / 2, y: along)
            mark.frame = CGRect(x: origin.x - bleed, y: origin.y - bleed,
                                width: config.logo + bleed * 2, height: config.logo + bleed * 2)
        }
        CATransaction.commit()
    }

    /// The bob is a translation, not a move to a second point: an absolute animation on `position` outlives
    /// every relayout — it keeps driving the presentation from the coordinates it was built with, so a mark
    /// sits where the old size put it however often the layout is redone.
    private func animate(config: LogoQueueConfig, animates: Bool) {
        let travel = config.logo * Self.travel
        let axis = config.edge.inward
        let vertical = axis.y != 0
        for (index, mark) in marks.enumerated() {
            mark.removeAnimation(forKey: "bob")
            guard animates, index < config.items.count else { continue }
            let period = max(0.25, config.items[index].isWorking ? config.workingSeconds : config.idleSeconds)
            let animation = CABasicAnimation(keyPath: vertical ? "transform.translation.y" : "transform.translation.x")
            animation.fromValue = 0
            animation.toValue = travel * CGFloat(vertical ? axis.y : axis.x)
            animation.duration = period / 2
            animation.autoreverses = true
            animation.repeatCount = .infinity
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            // A negative time offset starts each mark further into the cycle than the one before it.
            animation.timeOffset = -Double(index) * Self.stagger
            animation.isRemovedOnCompletion = false
            mark.add(animation, forKey: "bob")
        }
    }
}
