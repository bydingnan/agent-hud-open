import AppKit
import QuartzCore
import AgentHUDCore

/// Click-through window that hosts the glow bitmap and the expanded panel's drop shadow.
/// The canvas spans the display height and stays fixed during expansion; only the layers inside move.
@MainActor
final class GlowWindowController {
    let panel: OverlayPanel
    private let host = NSView()
    let glowLayer = CALayer()
    let shadowLayer = CALayer()
    private let alertLayer = CALayer()
    private var lastAlertID: String?
    private var softKey: SoftKey?
    private var glowPadding: CGFloat = 0
    private var shadowKey: ShadowKey?
    private var shadowPadding: CGFloat = 0
    private var breathKey: BreathKey?
    private var restingKey: GlowFrameRenderer.Key?
    /// The soft glow's resting bitmap, restored when a frame-by-frame effect stops.
    private var softStill: CGImage?
    private let frames = GlowFrameCache()
    private lazy var animator = GlowAnimator(host: host, layer: glowLayer)

    static let panelWidth: CGFloat = 1000

    /// Inputs of the soft glow bitmap.
    private struct SoftKey: Hashable {
        let glow: GlowGeometry
        let islandSize: CGSize
        let islandRadius: CGFloat
        let outwardOnly: Bool
        let stops: [GradientStop]
        let scale: CGFloat
    }

    private struct ShadowKey: Hashable {
        let size: CGSize
        let radius: CGFloat
        let scale: CGFloat
    }

    private struct BreathKey: Hashable {
        let pulses: Bool
        let peakOpacity: Double
        let troughOpacity: Double
        let breathSeconds: Double
    }

    init(geometry: NotchGeometry) {
        panel = OverlayPanel(frame: Self.panelFrame(for: geometry), level: .statusBar, acceptsMouse: false)
        panel.setAccessibilityElement(false)
        panel.setAccessibilityHidden(true)
        host.wantsLayer = true
        host.layer?.masksToBounds = true
        panel.contentView = host
        for layer in [shadowLayer, glowLayer, alertLayer] {
            layer.contentsGravity = .resize
            layer.contentsScale = geometry.backingScale
            layer.anchorPoint = .zero
            host.layer?.addSublayer(layer)
        }
        shadowLayer.opacity = 0
        alertLayer.opacity = 0
    }

    static func panelFrame(for geometry: NotchGeometry) -> CGRect {
        // A logo queue's backdrop falls only under the marks. The panel is exactly that column and clips
        // the field to it: the lip the field radiates from runs wider, so what is cut away is the part that
        // would otherwise curl in at the ends.
        guard geometry.mode != .logos else {
            return CGRect(x: geometry.rect.minX, y: geometry.screenFrame.minY,
                          width: geometry.rect.width, height: geometry.screenFrame.height)
        }
        return CGRect(
            x: geometry.centerX - panelWidth / 2,
            y: geometry.screenFrame.minY,
            width: panelWidth,
            height: geometry.screenFrame.height
        )
    }

    /// - island: the island's current frame in screen coordinates.
    func update(
        geometry: NotchGeometry,
        island: CGRect,
        islandRadius: CGFloat,
        glow: GlowGeometry,
        outwardOnly: Bool,
        appearance: GlowAppearance,
        animated: Bool,
        alert: IslandAlert? = nil,
        quotaVendors: [String] = [],
        pattern: GlowPattern = GlowPattern()
    ) {
        let frame = Self.panelFrame(for: geometry)
        if panel.frame != frame { panel.setFrame(frame, display: false) }
        glowLayer.contentsScale = geometry.backingScale
        shadowLayer.contentsScale = geometry.backingScale

        if appearance.hidden {
            animator.stop()
            softKey = nil
            restingKey = nil
            if panel.isVisible { panel.orderOut(nil) }
            return
        }
        if !panel.isVisible { panel.orderFrontRegardless() }

        // Island rect in the host's (bottom-left origin) coordinates.
        let local = CGRect(x: island.minX - frame.minX, y: island.minY - frame.minY, width: island.width, height: island.height)
        let glowTop = local.maxY - glow.topOffset
        let glowRect = CGRect(x: local.minX - glow.sideInset, y: glowTop - glow.height, width: glow.width, height: glow.height)

        let motion = Self.playsMotion(pattern: pattern, appearance: appearance,
                                      reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        if pattern.usesGrid {
            updateGridImage(glow: glow, islandRadius: islandRadius, stops: appearance.stops, scale: geometry.backingScale,
                            pattern: pattern, appearance: appearance, motion: motion)
        } else {
            restingKey = nil
            updateSoftImage(glow: glow, islandSize: island.size, islandRadius: islandRadius, outwardOnly: outwardOnly,
                            stops: appearance.stops, scale: geometry.backingScale, pattern: pattern, appearance: appearance,
                            motion: motion)
        }
        updateShadowImage(island: local, radius: islandRadius, scale: geometry.backingScale)

        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(IslandAnimation.duration)
            CATransaction.setAnimationTimingFunction(IslandAnimation.mediaCurve)
        } else {
            CATransaction.setDisableActions(true)
        }
        glowLayer.frame = glowRect.insetBy(dx: -glowPadding, dy: -glowPadding)
        alertLayer.frame = glowLayer.frame
        shadowLayer.frame = local.offsetBy(dx: 0, dy: -8).insetBy(dx: -shadowPadding, dy: -shadowPadding)
        shadowLayer.opacity = 1
        CATransaction.commit()

        // A running grid effect carries the breathing itself; otherwise the whole layer pulses.
        applyBreathing(appearance, pulsesOpacity: !animator.isRunning)
        applyAlert(alert, vendors: quotaVendors, glow: glow, islandSize: island.size, radius: islandRadius,
                   outwardOnly: outwardOnly, scale: geometry.backingScale, pattern: pattern)
    }

    /// Effects play frame by frame while an agent is running, collapsed or expanded alike; Reduce Motion keeps the
    /// resting frame. The soft glow's breathing stays a Core Animation opacity pulse.
    nonisolated static func playsMotion(pattern: GlowPattern, appearance: GlowAppearance, reduceMotion: Bool) -> Bool {
        (pattern.usesGrid || pattern.effect != .breathe) && appearance.breathing && !appearance.hidden && !reduceMotion
    }

    /// How deep the appearance breathes, as the fraction of brightness it loses at the trough.
    private static func breathDepth(_ appearance: GlowAppearance) -> Double {
        appearance.peakOpacity > 0 ? 1 - appearance.troughOpacity / appearance.peakOpacity : 0
    }

    /// The blurred bitmap stretches through its nine-slice centre while the island animates; a grid of dots
    /// would distort, so those bitmaps stay at native size, pinned to the screen edge, and the animating frame
    /// reveals or hides rows instead.
    private func configure(_ layer: CALayer, for style: GlowStyle, image: GlowImage, side: CGFloat, bottom: CGFloat) {
        if style == .blur {
            layer.contentsGravity = .resize
            layer.masksToBounds = false
            layer.contentsCenter = contentsCenter(for: image, side: side, bottom: bottom)
        } else {
            layer.contentsGravity = .top
            layer.masksToBounds = true
            layer.contentsCenter = CGRect(x: 0, y: 0, width: 1, height: 1)
        }
    }

    private func applyAlert(_ alert: IslandAlert?, vendors: [String], glow: GlowGeometry, islandSize: CGSize,
                            radius: CGFloat, outwardOnly: Bool, scale: CGFloat, pattern: GlowPattern) {
        guard lastAlertID != alert?.id else { return }
        lastAlertID = alert?.id
        alertLayer.removeAllAnimations()
        guard let alert else { return }
        let color = alert.accent
        let clear = color.withAlpha(0)
        let matches = vendors.indices.filter { vendors[$0] == alert.vendor }
        let stops: [GradientStop]
        if let first = matches.first, let last = matches.last {
            let count = Double(vendors.count)
            let left = Double(first) / count, right = Double(last + 1) / count
            let feather = 0.15 / count
            stops = [GradientStop(color: clear, location: max(0, left - feather)),
                     GradientStop(color: color, location: left + feather),
                     GradientStop(color: color, location: right - feather),
                     GradientStop(color: clear, location: min(1, right + feather))]
        } else {
            stops = [GradientStop(color: color, location: 0), GradientStop(color: color, location: 1)]
        }
        guard let rendered = GlowFrameRenderer.resting(.init(glow: glow, islandRadius: radius, stops: stops, scale: scale,
                                                             pattern: pattern, islandSize: islandSize,
                                                             outwardOnly: outwardOnly)) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        alertLayer.contents = rendered.image
        alertLayer.contentsScale = scale
        configure(alertLayer, for: pattern.style, image: rendered, side: glow.sideInset + radius, bottom: glow.sideInset + radius)
        CATransaction.commit()
        let pulse = CAKeyframeAnimation(keyPath: "opacity")
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            pulse.values = [0, 0.12, 0]
            pulse.keyTimes = [0, 0.3, 1]
        } else if alert.isWarning {
            pulse.values = [0, 0.22, 0.05, 0.22, 0]
            pulse.keyTimes = [0, 0.2, 0.45, 0.65, 1]
        } else {
            pulse.values = [0, 0.22, 0.15, 0]
            pulse.keyTimes = [0, 0.25, 0.65, 1]
        }
        pulse.duration = 1.8
        pulse.calculationMode = .linear
        alertLayer.add(pulse, forKey: "quota-event")
    }

    private func updateGridImage(glow: GlowGeometry, islandRadius: CGFloat, stops: [GradientStop], scale: CGFloat,
                                 pattern: GlowPattern, appearance: GlowAppearance, motion: Bool) {
        let renderer = frames.renderer(for: .init(glow: glow, islandRadius: islandRadius, stops: stops, scale: scale, pattern: pattern,
                                                  colorSpace: panel.screen?.colorSpace?.cgColorSpace))
        softKey = nil
        glowPadding = 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glowLayer.contentsGravity = .top
        glowLayer.masksToBounds = true
        glowLayer.contentsCenter = CGRect(x: 0, y: 0, width: 1, height: 1)
        CATransaction.commit()
        if motion {
            restingKey = nil
            animator.play(renderer, breathSeconds: appearance.breathSeconds, breathAmplitude: Self.breathDepth(appearance))
        } else if animator.isRunning && !appearance.hidden {
            // The last agent went idle: ease back into the resting frame.
            animator.settle(renderer) { [weak self] in self?.showResting(renderer) }
        } else {
            animator.stop()
            showResting(renderer)
        }
    }

    /// The soft glow keeps its nine-slice bitmap. Effects other than breathing swap in frames of the same size and
    /// layout, and hand the resting bitmap back when they stop.
    private func updateSoftImage(glow: GlowGeometry, islandSize: CGSize, islandRadius: CGFloat, outwardOnly: Bool, stops: [GradientStop],
                                 scale: CGFloat, pattern: GlowPattern, appearance: GlowAppearance, motion: Bool) {
        updateGlowImage(glow: glow, islandSize: islandSize, islandRadius: islandRadius, outwardOnly: outwardOnly, stops: stops, scale: scale)
        guard pattern.effect != .breathe else { return stopSoftMotion() }
        let renderer = frames.renderer(for: .init(glow: glow, islandRadius: islandRadius, stops: stops, scale: scale, pattern: pattern,
                                                  colorSpace: panel.screen?.colorSpace?.cgColorSpace,
                                                  islandSize: islandSize, outwardOnly: outwardOnly))
        if motion {
            animator.play(renderer, breathSeconds: appearance.breathSeconds, breathAmplitude: Self.breathDepth(appearance))
        } else if animator.isRunning && !appearance.hidden {
            animator.settle(renderer) { [weak self] in self?.restoreSoftStill() }
        } else {
            stopSoftMotion()
        }
    }

    private func stopSoftMotion() {
        guard animator.isRunning else { return }
        animator.stop()
        restoreSoftStill()
    }

    private func restoreSoftStill() {
        guard let softStill else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glowLayer.contents = softStill
        CATransaction.commit()
    }

    private func showResting(_ renderer: GlowFrameRenderer) {
        guard restingKey != renderer.key,
              let rendered = renderer.render(time: 0, blend: 0, breathSeconds: 0, breathAmplitude: 0) else { return }
        restingKey = renderer.key
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glowLayer.contents = rendered.image
        CATransaction.commit()
    }

    private func updateGlowImage(glow: GlowGeometry, islandSize: CGSize, islandRadius: CGFloat, outwardOnly: Bool,
                                 stops: [GradientStop], scale: CGFloat) {
        let key = SoftKey(glow: glow, islandSize: islandSize, islandRadius: islandRadius, outwardOnly: outwardOnly, stops: stops, scale: scale)
        guard key != softKey else { return }
        guard let rendered = GlowRenderer.render(
            glow: glow, islandSize: islandSize, islandRadius: islandRadius, outwardOnly: outwardOnly, stops: stops, scale: scale
        ) else { return }
        softKey = key
        glowPadding = rendered.padding
        softStill = rendered.image
        CATransaction.begin()
        // A contents crossfade has its own timing and stretches the old contour into the new one.
        // Only animate the frame; keep the feather and rounded edge at their native point size.
        CATransaction.setDisableActions(true)
        glowLayer.contents = rendered.image
        configure(glowLayer, for: .blur, image: rendered, side: glow.sideInset + islandRadius, bottom: glow.sideInset + islandRadius)
        CATransaction.commit()
    }

    private func updateShadowImage(island: CGRect, radius: CGFloat, scale: CGFloat) {
        let key = ShadowKey(size: island.size, radius: radius, scale: scale)
        guard key != shadowKey else { return }
        guard let rendered = GlowRenderer.renderShadow(width: island.width, height: island.height, cornerRadius: radius, scale: scale) else { return }
        shadowKey = key
        shadowPadding = rendered.padding
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shadowLayer.contents = rendered.image
        shadowLayer.contentsCenter = contentsCenter(for: rendered, side: radius, bottom: radius)
        CATransaction.commit()
    }

    private func contentsCenter(for image: GlowImage, side: CGFloat, bottom: CGFloat) -> CGRect {
        let left = min(image.padding + side, (image.size.width - 1) / 2)
        let top = image.padding
        let lower = min(image.padding + bottom, image.size.height - top - 1)
        return CGRect(x: left / image.size.width, y: top / image.size.height,
                      width: (image.size.width - left * 2) / image.size.width,
                      height: (image.size.height - top - lower) / image.size.height)
    }

    private func applyBreathing(_ appearance: GlowAppearance, pulsesOpacity: Bool) {
        let pulses = appearance.breathing && pulsesOpacity
        let key = BreathKey(pulses: pulses, peakOpacity: appearance.peakOpacity, troughOpacity: appearance.troughOpacity,
                            breathSeconds: appearance.breathSeconds)
        guard key != breathKey else { return }
        breathKey = key
        glowLayer.removeAnimation(forKey: "breathe")
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.3)
        glowLayer.opacity = Float(appearance.peakOpacity)
        CATransaction.commit()
        guard pulses else { return }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = appearance.peakOpacity
        animation.toValue = appearance.troughOpacity
        animation.duration = appearance.breathSeconds / 2
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        glowLayer.add(animation, forKey: "breathe")
    }
}
