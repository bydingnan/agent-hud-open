import AppKit
import CoreGraphics

/// One agent's mark, baked at the size it will be drawn with its outline already in the pixels.
///
/// The outline has to follow the artwork's own silhouette, which no border or single shadow can do for an
/// arbitrary mark. Stacking live shadows does it but costs an offscreen pass per direction per frame, and
/// the queue animates — so the ring is drawn once here instead, from the artwork's alpha, and the animating
/// layer ends up with nothing but a flat image to composite.
@MainActor
enum LogoImages {
    struct Key: Hashable {
        var vendor: String
        /// Side of the mark in device pixels, excluding the outline.
        var side: Int
        /// Outline thickness in device pixels.
        var outline: Int
        /// Which artwork variant to bake, for the vendors that ship one per background. It does not choose
        /// the ink: a single-colour mark is always drawn light, because what sits behind the queue is the
        /// wallpaper, not an app surface, and the system's appearance says nothing about the contrast there.
        var light: Bool
    }

    private static var cache: [Key: CGImage] = [:]

    /// The baked mark, and how far it overflows the nominal side on each edge.
    static func image(_ key: Key) -> CGImage? {
        if let hit = cache[key] { return hit }
        guard let image = render(key) else { return nil }
        if cache.count > 96 { cache.removeAll(keepingCapacity: true) }
        cache[key] = image
        return image
    }

    static func invalidate() { cache.removeAll(keepingCapacity: true) }

    private static func render(_ key: Key) -> CGImage? {
        guard key.side > 0,
              let artwork = AgentArtwork.original(for: key.vendor, light: key.light),
              let mark = cgImage(artwork)
        else { return nil }
        let outline = CGFloat(max(0, key.outline))
        let side = CGFloat(key.side)
        let canvas = Int((side + outline * 2).rounded())
        guard let context = CGContext(
            data: nil, width: canvas, height: canvas, bitsPerComponent: 8, bytesPerRow: canvas * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        let rect = CGRect(x: outline, y: outline, width: side, height: side)

        if outline > 0 {
            // Eight directions: four would leave the diagonals bare at this thickness.
            context.setFillColor(NSColor.black.withAlphaComponent(0.55).cgColor)
            for angle in stride(from: 0.0, to: 2 * .pi, by: .pi / 4) {
                let offset = CGPoint(x: cos(angle) * outline, y: sin(angle) * outline)
                context.saveGState()
                context.clip(to: rect.offsetBy(dx: offset.x, dy: offset.y), mask: mark)
                context.fill(rect.offsetBy(dx: offset.x, dy: offset.y))
                context.restoreGState()
            }
        }

        if AgentArtwork.isTemplate(key.vendor) {
            // A single-colour mark carries no colour of its own; it is drawn as a white stencil, with the
            // outline above doing the work on a pale wallpaper.
            context.saveGState()
            context.clip(to: rect, mask: mark)
            context.setFillColor(NSColor.white.cgColor)
            context.fill(rect)
            context.restoreGState()
        } else {
            context.draw(mark, in: rect)
        }
        return context.makeImage()
    }

    private static func cgImage(_ image: NSImage) -> CGImage? {
        var rect = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
}
