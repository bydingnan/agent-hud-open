import AppKit
import CoreText
import AgentHUDCore

/// Draws animated glow frames for every style. Grid styles follow the ASCII HUD bar design: the grid, palette and
/// glyphs are prepared once per geometry, and a frame only evaluates the motion effect and draws a few hundred
/// marks, dots in one path per colour and characters through Core Text's glyph cache. The soft style keeps its
/// blurred bitmap and multiplies it by a coarse gain field that the context scales up smoothly, recolouring it for
/// flow, so each frame is two image draws.
final class GlowFrameRenderer {
    struct Key: Hashable {
        let glow: GlowGeometry
        let islandRadius: CGFloat
        let stops: [GradientStop]
        let scale: CGFloat
        let pattern: GlowPattern
        /// The destination screen's colour space; nil draws sRGB.
        var colorSpace: CGColorSpace? = nil
        /// The soft style's island and falloff, which shape its blurred bitmap.
        var islandSize: CGSize = .zero
        var outwardOnly: Bool = true
    }

    private static let paletteSize = 64
    /// Flow lightens colours in steps toward white, at most by this much.
    private static let sheenLevels = 8
    private static let sheenStrength = 0.45
    /// The soft style has no grid; its effects use this length for bands, ripples and noise patches, and sample
    /// their gain on cells of `softFieldCell` points.
    static let softPitch = 8.0
    fileprivate static let softFieldCell = 4.0
    /// Density ramps from faint to strong. Blocks end in a solid cell, drawn as a rectangle.
    static let asciiRamp: [Character] = Array(".:-=+*#%@")
    static let blockRamp: [Character] = Array("░▒▓")
    static let binaryDigits: [Character] = Array("01")

    let key: Key
    private let matrix: GlowMatrix
    /// Colours by gradient position, each with `levels` sheen steps.
    private let palette: [CGColor]
    /// The palette as premultiplied RGBA bytes, for writing the soft glow's flow strip directly.
    private let paletteBytes: [UInt8]
    private let levels: Int
    private let soft: SoftGlow?
    /// Cell centres in bitmap points (origin bottom-left), snapped to device pixels.
    private let centers: [CGPoint]
    private let glyphs: GlyphSet?
    private let brailleDots: [[(bit: Int, dot: GlowMatrix.Cell)]]

    init(_ key: Key) {
        self.key = key
        let scale = max(1, key.scale)
        // Whole device pixels keep every mark the same size.
        let pitch = max(1 / scale, (key.pattern.pitch * scale).rounded() / scale)
        let matrix = key.pattern.usesGrid
            ? GlowMatrix.compute(glow: key.glow, islandRadius: key.islandRadius, pitch: pitch, spread: key.pattern.spread)
            : GlowMatrix(cells: [], pitch: Self.softPitch, spread: key.pattern.spread)
        self.matrix = matrix
        let levels = key.pattern.effect == .flow ? Self.sheenLevels : 1
        self.levels = levels
        palette = (0..<Self.paletteSize).flatMap { index in
            let base = GlowGradient.color(at: Double(index) / Double(Self.paletteSize - 1), stops: key.stops)
            return (0..<levels).map { level in
                let sheen = levels > 1 ? Self.sheenStrength * Double(level) / Double(levels - 1) : 0
                let color = CGColor.rgba(base.mixed(with: .white, amount: sheen))
                return key.colorSpace.flatMap { color.converted(to: $0, intent: .defaultIntent, options: nil) } ?? color
            }
        }
        soft = key.pattern.usesGrid ? nil : SoftGlow(key: key)
        paletteBytes = soft != nil && key.pattern.effect == .flow ? palette.flatMap { color -> [UInt8] in
            guard let c = color.components, c.count >= 4 else { return [0, 0, 0, 0] }
            return [c[0] * c[3], c[1] * c[3], c[2] * c[3], c[3]].map { UInt8((min(1, max(0, $0)) * 255).rounded()) }
        } : []
        centers = matrix.cells.map { cell in
            CGPoint(x: (cell.x * scale).rounded() / scale, y: ((key.glow.height - cell.y) * scale).rounded() / scale)
        }
        glyphs = GlyphSet(style: key.pattern.style, size: pitch, density: key.pattern.density)
        brailleDots = key.pattern.style == .braille
            ? matrix.cells.map { matrix.brailleDots(of: $0, glow: key.glow, islandRadius: key.islandRadius) }
            : []
    }

    var cellCount: Int { matrix.cells.count }

    /// - time: seconds since the effect started.
    /// - blend: 0 draws the resting glow and 1 the full effect; values in between ease the effect in or out.
    func render(time: Double, blend: Double, breathSeconds: Double, breathAmplitude: Double) -> GlowImage? {
        let motion = Motion(effect: key.pattern.effect, time: time, blend: min(1, max(0, blend)), pitch: matrix.pitch,
                            glowWidth: key.glow.width, breathSeconds: breathSeconds, breathAmplitude: breathAmplitude,
                            levels: levels)
        if let soft { return renderSoft(soft, motion: motion) }
        return GlowRenderer.renderBitmap(width: key.glow.width, height: key.glow.height, blur: 0, padding: 0, scale: key.scale,
                                         colorSpace: key.colorSpace) { _, context, _ in
            switch key.pattern.style {
            case .dots: drawDots(in: context, motion: motion)
            case .braille: drawBraille(in: context, motion: motion)
            case .ascii, .blocks, .binary: drawCharacters(in: context, motion: motion)
            case .blur: break
            }
        }
    }

    private func paletteIndex(for cell: GlowMatrix.Cell, _ motion: Motion) -> Int {
        let bucket = Int((min(1, max(0, motion.location(cell))) * Double(Self.paletteSize - 1)).rounded())
        return bucket * levels + motion.sheenLevel(cell)
    }

    private func color(for cell: GlowMatrix.Cell, _ motion: Motion) -> CGColor {
        palette[paletteIndex(for: cell, motion)]
    }

    /// The resting soft bitmap, recoloured for flow or multiplied by the effect's gain field.
    private func renderSoft(_ soft: SoftGlow, motion: Motion) -> GlowImage? {
        guard motion.blend > 0 else { return soft.base }
        let size = soft.base.size, padding = soft.base.padding
        return GlowRenderer.renderBitmap(width: size.width - 2 * padding, height: size.height - 2 * padding, blur: 0,
                                         padding: padding, scale: key.scale, colorSpace: key.colorSpace) { _, context, _ in
            let full = CGRect(origin: .zero, size: size)
            // Same-size bitmaps are copied pixel for pixel; only the coarse fields are scaled smoothly.
            context.interpolationQuality = .none
            switch key.pattern.effect {
            case .flow:
                guard let shape = soft.shape, let strip = flowStrip(soft, motion: motion) else {
                    return context.draw(soft.base.image, in: full)
                }
                context.clip(to: full, mask: shape)
                context.draw(strip, in: full)
            case .breathe:
                context.setAlpha(motion.value(soft.cells[0]))
                context.draw(soft.base.image, in: full)
            case .scan, .ripple, .shimmer, .boot:
                // The gain field is a grey mask: scaled over the bitmap, its values multiply the glow's alpha.
                if let gain = gainField(soft, motion: motion) {
                    context.interpolationQuality = .medium
                    context.clip(to: full, mask: gain)
                    context.interpolationQuality = .none
                }
                context.draw(soft.base.image, in: full)
            }
        }
    }

    /// An image the size of the bitmap whose every row holds each field column's flowing, sheened colour, so it is
    /// drawn with a plain pixel copy.
    private func flowStrip(_ soft: SoftGlow, motion: Motion) -> CGImage? {
        let width = soft.base.image.width, height = soft.base.image.height
        guard width > 0, height > 0, let space = GlowRenderer.bitmapSpace(key.colorSpace),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { return nil }
        let pixels = data.assumingMemoryBound(to: UInt8.self)
        let glowWidth = max(1, key.glow.width)
        let pointsPerPixel = soft.base.size.width / Double(width)
        let lastBucket = Double(Self.paletteSize - 1), lastLevel = Double(levels - 1)
        for x in 0..<width {
            // Position and sheen per pixel column, blended between neighbouring palette entries so neither the
            // gradient nor the light band shows steps.
            let location = ((Double(x) + 0.5) * pointsPerPixel - soft.base.padding) / glowWidth
            let cell = GlowMatrix.Cell(column: 0, row: 0, x: 0, y: 0, width: 0, distance: 0, intensity: 1, location: location)
            let flowing = min(1, max(0, motion.location(cell))) * lastBucket
            let sheen = min(lastLevel, GlowMotion.sheen(.flow, location: location, time: motion.time) * motion.blend * lastLevel)
            let b0 = min(Int(flowing), Self.paletteSize - 2), l0 = min(Int(sheen), max(0, levels - 2))
            let fb = flowing - Double(b0), fl = levels > 1 ? sheen - Double(l0) : 0
            for channel in 0..<4 {
                let entry = { (bucket: Int, level: Int) in Double(self.paletteBytes[(bucket * self.levels + level) * 4 + channel]) }
                let low = entry(b0, l0) * (1 - fb) + entry(b0 + 1, l0) * fb
                let high = levels > 1 ? entry(b0, l0 + 1) * (1 - fb) + entry(b0 + 1, l0 + 1) * fb : low
                pixels[x * 4 + channel] = UInt8((low * (1 - fl) + high * fl).rounded())
            }
        }
        for row in 1..<height { memcpy(pixels + row * width * 4, pixels, width * 4) }
        return context.makeImage()
    }

    /// The effect's gain per field cell as a grey clipping mask; rows run top-down like the glow. (An alpha-only
    /// bitmap would become a stencil mask, which paints rather than multiplies.)
    private func gainField(_ soft: SoftGlow, motion: Motion) -> CGImage? {
        guard let context = CGContext(data: nil, width: soft.columns, height: soft.rows, bitsPerComponent: 8, bytesPerRow: soft.columns,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let data = context.data else { return nil }
        let pixels = data.assumingMemoryBound(to: UInt8.self)
        for (index, cell) in soft.cells.enumerated() {
            pixels[index] = UInt8((motion.value(cell) * 255).rounded())
        }
        return context.makeImage()
    }

    /// Halftone: one filled path per palette colour.
    private func drawDots(in context: CGContext, motion: Motion) {
        var paths = [CGMutablePath?](repeating: nil, count: palette.count)
        for (index, cell) in matrix.cells.enumerated() {
            let value = motion.value(cell)
            guard value >= GlowMatrix.cutoff else { continue }
            let radius = matrix.pitch * key.pattern.density * (0.07 + 0.45 * value.squareRoot())
            let center = centers[index]
            let bucket = paletteIndex(for: cell, motion)
            let path = paths[bucket] ?? CGMutablePath()
            path.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            paths[bucket] = path
        }
        for (bucket, path) in paths.enumerated() {
            guard let path else { continue }
            context.setFillColor(palette[bucket])
            context.addPath(path)
            context.fillPath()
        }
    }

    /// ASCII, blocks and binary: one glyph per cell, brighter where the glow is stronger.
    private func drawCharacters(in context: CGContext, motion: Motion) {
        guard let glyphs else { return }
        prepareText(context)
        let style = key.pattern.style
        for (index, cell) in matrix.cells.enumerated() {
            let value = motion.value(cell)
            guard value >= GlowMatrix.cutoff else { continue }
            var alpha = 0.45 + 0.55 * value.squareRoot()
            let glyph: Int
            switch style {
            case .blocks:
                let level = Self.level(value, count: Self.blockRamp.count + 1, shift: motion.levelShift(cell))
                if level == Self.blockRamp.count {
                    context.setAlpha(alpha)
                    context.setFillColor(color(for: cell, motion))
                    context.fill(cellRect(index: index, cell: cell))
                    continue
                }
                glyph = level
            case .binary:
                let on = 0.1 + 0.9 * value > GlowMotion.ditherThreshold(column: cell.column, row: cell.row)
                glyph = on ? 1 : 0
                if !on { alpha *= 0.35 }
            default:
                glyph = Self.level(value, count: Self.asciiRamp.count, shift: motion.levelShift(cell))
            }
            context.setAlpha(alpha)
            context.setFillColor(color(for: cell, motion))
            glyphs.draw(glyph, centeredAt: centers[index], in: context)
        }
    }

    /// Braille: each of a cell's eight dots is dithered from its own sample; the cell's glyph shows the result.
    private func drawBraille(in context: CGContext, motion: Motion) {
        guard let glyphs else { return }
        prepareText(context)
        for (index, cell) in matrix.cells.enumerated() {
            var code = 0
            for (bit, dot) in brailleDots[index] {
                let value = motion.value(dot)
                if value >= GlowMatrix.cutoff, 0.1 + 0.9 * value > GlowMotion.ditherThreshold(column: dot.column, row: dot.row) {
                    code |= 1 << bit
                }
            }
            guard code != 0 else { continue }
            context.setAlpha(0.45 + 0.55 * motion.value(cell).squareRoot())
            context.setFillColor(color(for: cell, motion))
            glyphs.draw(code, centeredAt: centers[index], in: context)
        }
    }

    private func prepareText(_ context: CGContext) {
        context.textMatrix = .identity
        context.setShouldSmoothFonts(false)
    }

    /// A solid block: the cell grown by density around its centre, snapped to device pixels so neighbouring
    /// blocks meet without seams (or overlap, above full density).
    private func cellRect(index: Int, cell: GlowMatrix.Cell) -> CGRect {
        let scale = max(1, key.scale)
        let snap = { (value: Double) in (value * scale).rounded() / scale }
        let halfWidth = cell.width * key.pattern.density / 2, halfHeight = matrix.pitch * key.pattern.density / 2
        let minX = snap(cell.x - halfWidth), maxX = snap(cell.x + halfWidth)
        let minY = snap(key.glow.height - cell.y - halfHeight), maxY = snap(key.glow.height - cell.y + halfHeight)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// A density level in 0..<count, shifted by jitter and clamped.
    private static func level(_ value: Double, count: Int, shift: Int) -> Int {
        min(count - 1, max(0, min(count - 1, Int(value * Double(count))) + shift))
    }

    private struct Motion {
        let effect: GlowEffect
        let time: Double
        let blend: Double
        let pitch: Double
        let glowWidth: Double
        let breathSeconds: Double
        let breathAmplitude: Double
        let levels: Int

        /// Which of the palette's sheen steps a cell uses.
        func sheenLevel(_ cell: GlowMatrix.Cell) -> Int {
            guard levels > 1, blend > 0 else { return 0 }
            let sheen = GlowMotion.sheen(effect, location: cell.location, time: time) * blend
            return min(levels - 1, Int((sheen * Double(levels - 1)).rounded()))
        }

        func value(_ cell: GlowMatrix.Cell) -> Double {
            guard blend > 0 else { return cell.intensity }
            let gain = GlowMotion.gain(effect, cell: cell, time: time, pitch: pitch, glowWidth: glowWidth,
                                       breathSeconds: breathSeconds, breathAmplitude: breathAmplitude)
            return min(1, cell.intensity * (1 + (gain - 1) * blend))
        }

        func location(_ cell: GlowMatrix.Cell) -> Double {
            guard blend > 0, effect == .flow else { return cell.location }
            return cell.location + (GlowMotion.location(.flow, cell: cell, time: time) - cell.location) * blend
        }

        func levelShift(_ cell: GlowMatrix.Cell) -> Int {
            guard blend >= 0.5 else { return 0 }
            return GlowMotion.jitterShift(GlowMotion.jitter(effect, cell: cell, time: time, pitch: pitch), cell: cell, time: time)
        }
    }
}

/// The glyphs one character style draws, in a font that has them, with offsets that centre each glyph in its cell.
/// Density scales the font within the fixed grid, so dense glyphs may overlap their neighbours.
private struct GlyphSet {
    let font: CTFont
    let glyphs: [CGGlyph]
    let advances: [CGFloat]
    /// Distance from the baseline up to the glyph's visual centre.
    let lift: CGFloat

    init?(style: GlowStyle, size: CGFloat, density: Double) {
        let density = CGFloat(max(0.1, density))
        let mono = { (size: CGFloat) in NSFont.monospacedSystemFont(ofSize: size, weight: .medium) as CTFont }
        switch style {
        case .blur, .dots:
            return nil
        case .ascii:
            self.init(font: mono(size * density), characters: GlowFrameRenderer.asciiRamp, centreOn: nil)
        case .binary:
            self.init(font: mono(size * density), characters: GlowFrameRenderer.binaryDigits, centreOn: nil)
        case .blocks:
            self.init(font: mono(size * density), characters: GlowFrameRenderer.blockRamp, centreOn: "█")
        case .braille:
            // The monospaced system font has no Braille; Core Text supplies a font that does.
            let base = CTFontCreateForString(mono(size), "⣿" as CFString, CFRange(location: 0, length: 1))
            let font = CTFontCreateCopyWithAttributes(base, size * density, nil, nil)
            let patterns = (0..<256).compactMap { UnicodeScalar(0x2800 + $0).map(Character.init) }
            self.init(font: font, characters: patterns, centreOn: "⣿")
        }
    }

    /// - centreOn: a glyph whose bounds set the vertical centre (a full block or Braille cell); nil uses half
    ///   the cap height, which keeps punctuation on the baseline like text.
    private init(font: CTFont, characters: [Character], centreOn reference: Character?) {
        var units = characters.map { String($0).utf16.first ?? 0x20 }
        var glyphs = [CGGlyph](repeating: 0, count: units.count)
        CTFontGetGlyphsForCharacters(font, &units, &glyphs, units.count)
        var advances = [CGSize](repeating: .zero, count: glyphs.count)
        CTFontGetAdvancesForGlyphs(font, .horizontal, &glyphs, &advances, glyphs.count)
        self.font = font
        self.glyphs = glyphs
        self.advances = advances.map(\.width)
        if let reference, var unit = String(reference).utf16.first {
            var glyph: CGGlyph = 0
            CTFontGetGlyphsForCharacters(font, &unit, &glyph, 1)
            lift = CTFontGetBoundingRectsForGlyphs(font, .horizontal, &glyph, nil, 1).midY
        } else {
            lift = CTFontGetCapHeight(font) / 2
        }
    }

    func draw(_ index: Int, centeredAt center: CGPoint, in context: CGContext) {
        var glyph = glyphs[index]
        var position = CGPoint(x: center.x - advances[index] / 2, y: center.y - lift)
        CTFontDrawGlyphs(font, &glyph, &position, 1, context)
    }
}

/// The soft glow's resting bitmap plus the coarse field its effects are evaluated on.
private struct SoftGlow {
    let base: GlowImage
    /// The glow's coverage as a grey clipping mask, recoloured by flow.
    let shape: CGImage?
    let columns: Int
    let rows: Int
    /// Field cells, top row first, in glow-rect coordinates; noise indices step every `softPitch` points.
    let cells: [GlowMatrix.Cell]

    init?(key: GlowFrameRenderer.Key) {
        guard let base = GlowRenderer.render(glow: key.glow, islandSize: key.islandSize, islandRadius: key.islandRadius,
                                             outwardOnly: key.outwardOnly, stops: key.stops, scale: key.scale,
                                             colorSpace: key.colorSpace) else { return nil }
        self.base = base
        let white = [GradientStop(color: .white, location: 0), GradientStop(color: .white, location: 1)]
        shape = key.pattern.effect == .flow
            ? GlowRenderer.render(glow: key.glow, islandSize: key.islandSize, islandRadius: key.islandRadius,
                                  outwardOnly: key.outwardOnly, stops: white, scale: key.scale).flatMap { Self.coverageMask($0.image) }
            : nil
        let columns = max(1, Int((base.size.width / GlowFrameRenderer.softFieldCell).rounded(.up)))
        let rows = max(1, Int((base.size.height / GlowFrameRenderer.softFieldCell).rounded(.up)))
        self.columns = columns
        self.rows = rows
        let pitch = GlowFrameRenderer.softPitch
        cells = (0..<rows).flatMap { row in
            (0..<columns).map { column in
                let x = (Double(column) + 0.5) * base.size.width / Double(columns) - base.padding
                let y = (Double(row) + 0.5) * base.size.height / Double(rows) - base.padding
                let distance = max(0, GlowMatrix.distance(x: x, y: y, glow: key.glow, islandRadius: key.islandRadius))
                return GlowMatrix.Cell(column: Int((x / pitch).rounded(.down)), row: Int((y / pitch).rounded(.down)), x: x, y: y,
                                       width: base.size.width / Double(columns), distance: distance, intensity: 1,
                                       location: x / max(1, key.glow.width))
            }
        }
    }
}

private extension SoftGlow {
    /// A grey image whose values are the source's alpha, usable with `CGContext.clip(to:mask:)`.
    static func coverageMask(_ image: CGImage) -> CGImage? {
        let width = image.width, height = image.height
        guard let rgba = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                   space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let grey = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                   space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let source = rgba.data, let target = grey.data else { return nil }
        rgba.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let from = source.assumingMemoryBound(to: UInt8.self), to = target.assumingMemoryBound(to: UInt8.self)
        for pixel in 0..<(width * height) { to[pixel] = from[pixel * 4 + 3] }
        return grey.makeImage()
    }
}

/// Keeps the renderer for the current geometry so consecutive frames skip the grid setup.
@MainActor
final class GlowFrameCache {
    private var current: GlowFrameRenderer?

    func renderer(for key: GlowFrameRenderer.Key) -> GlowFrameRenderer {
        if let current, current.key == key { return current }
        let renderer = GlowFrameRenderer(key)
        current = renderer
        return renderer
    }
}
