import Foundation

/// Options for the dot and ASCII glow styles.
public struct GlowPattern: Hashable, Sendable {
    public var style: GlowStyle
    /// Grid spacing in points.
    public var pitch: Double
    /// Decay length of the glow in grid cells.
    public var spread: Double
    /// How much of its cell each mark fills; 1 is the design's proportion.
    public var density: Double
    public var effect: GlowEffect

    public init(style: GlowStyle = .blur, pitch: Double = 10, spread: Double = 2.4, density: Double = 1, effect: GlowEffect = .breathe) {
        self.style = style
        self.pitch = pitch
        self.spread = spread
        self.density = density
        self.effect = effect
    }

    public var usesGrid: Bool { style != .blur }
}

public extension Settings {
    /// Grid options with the pitch scaled like range and feather for small previews.
    func glowPattern(scale: Double = 1) -> GlowPattern {
        GlowPattern(style: glowStyle, pitch: glowGridPitch * scale, spread: glowGridSpread, density: glowGridDensity, effect: glowEffect)
    }

    /// The glow rect around an island. The blurred style uses range and feather; the grid styles size the rect
    /// to the farthest dot, with no blur margin above the screen edge.
    func glowGeometry(islandWidth: Double, islandHeight: Double, islandRadius: Double, scale: Double = 1) -> GlowGeometry {
        guard glowStyle != .blur else {
            return GlowGeometry.compute(islandWidth: islandWidth, islandHeight: islandHeight, islandRadius: islandRadius,
                                        range: glowRange * scale, blur: glowBlur * scale)
        }
        let reach = GlowMatrix.reach(pitch: glowGridPitch * scale, spread: glowGridSpread)
        return GlowGeometry.compute(islandWidth: islandWidth, islandHeight: islandHeight, islandRadius: islandRadius,
                                    range: reach.rounded(.up), blur: 0)
    }
}

/// The glow sampled on a square grid, following the ASCII HUD bar design: every cell's resting intensity is
/// e^(−distance / (spread · pitch)), measured from the island's outline. Pure geometry; the desktop renderer
/// decides how each cell is drawn. Coordinates are points from the glow rect's top-left corner.
public struct GlowMatrix: Hashable, Sendable {
    public struct Cell: Hashable, Sendable {
        public init(column: Int, row: Int, x: Double, y: Double, width: Double, distance: Double, intensity: Double, location: Double) {
            self.column = column
            self.row = row
            self.x = x
            self.y = y
            self.width = width
            self.distance = distance
            self.intensity = intensity
            self.location = location
        }

        public let column: Int
        public let row: Int
        public let x: Double
        public let y: Double
        /// Width of the cell's column; the columns under the island stretch slightly to fit it.
        public let width: Double
        /// Distance from the island's outline in points.
        public let distance: Double
        /// 0…1 resting strength of the glow at this cell.
        public let intensity: Double
        /// 0…1 across the glow's width; where this cell samples the colour gradient.
        public let location: Double
    }

    public let cells: [Cell]
    public let pitch: Double
    public let spread: Double

    public init(cells: [Cell], pitch: Double, spread: Double) {
        self.cells = cells
        self.pitch = pitch
        self.spread = spread
    }

    /// Marks fainter than this are not drawn.
    public static let cutoff = 0.06

    /// Farthest distance a mark can appear at, allowing for effects that lift the glow above rest.
    public static func reach(pitch: Double, spread: Double) -> Double {
        max(0, spread) * pitch * log(GlowMotion.maximumGain / cutoff)
    }

    /// Columns beside the island start half a pitch from its sides and the row below it half a pitch from its
    /// bottom edge, so the first ring sits tangent to the rim. Cells over the island, above the screen edge or
    /// too faint for any effect to reveal are skipped.
    public static func compute(glow: GlowGeometry, islandRadius: Double, pitch: Double, spread: Double) -> GlowMatrix {
        let pitch = max(0.5, pitch)
        let decay = max(0.1, spread) * pitch
        let faintest = cutoff / GlowMotion.maximumGain
        let left = glow.sideInset
        let right = glow.width - glow.sideInset
        let bottom = glow.height - glow.sideInset
        let top = -glow.topOffset

        var columns: [(x: Double, width: Double)] = []
        var x = left - pitch / 2
        while x > 0 { columns.append((x, pitch)); x -= pitch }
        let middle = max(1, ((right - left) / pitch).rounded())
        let middlePitch = (right - left) / middle
        for index in 0..<Int(middle) { columns.append((left + (Double(index) + 0.5) * middlePitch, middlePitch)) }
        x = right + pitch / 2
        while x < glow.width { columns.append((x, pitch)); x += pitch }
        columns.sort { $0.x < $1.x }

        var ys: [Double] = []
        var y = bottom + pitch / 2
        while y < glow.height { ys.append(y); y += pitch }
        y = bottom - pitch / 2
        while y >= top { ys.append(y); y -= pitch }

        var cells: [Cell] = []
        for (row, y) in ys.sorted().enumerated() {
            for (column, place) in columns.enumerated() {
                let distance = distance(x: place.x, y: y, glow: glow, islandRadius: islandRadius)
                guard distance >= 0 else { continue }
                let intensity = exp(-distance / decay)
                guard intensity >= faintest else { continue }
                cells.append(Cell(column: column, row: row, x: place.x, y: y, width: place.width, distance: distance,
                                  intensity: intensity, location: place.x / glow.width))
            }
        }
        return GlowMatrix(cells: cells, pitch: pitch, spread: spread)
    }

    /// Dot positions of a Braille character as (column, row, Unicode bit).
    public static let brailleLayout: [(column: Int, row: Int, bit: Int)] = [
        (0, 0, 0), (0, 1, 1), (0, 2, 2), (1, 0, 3), (1, 1, 4), (1, 2, 5), (0, 3, 6), (1, 3, 7),
    ]

    /// The eight dots of a cell drawn as a Braille character, 2 across and 4 down, each sampled on its own as
    /// in the design. Dots over the island are left out; grid indices are per dot for dithering and noise.
    public func brailleDots(of cell: Cell, glow: GlowGeometry, islandRadius: Double) -> [(bit: Int, dot: Cell)] {
        let decay = max(0.1, spread) * pitch
        return Self.brailleLayout.compactMap { layout in
            let x = cell.x - cell.width / 2 + (Double(layout.column) + 0.5) * cell.width / 2
            let y = cell.y - pitch / 2 + (Double(layout.row) + 0.5) * pitch / 4
            let distance = Self.distance(x: x, y: y, glow: glow, islandRadius: islandRadius)
            guard distance >= 0 else { return nil }
            let dot = Cell(column: cell.column * 2 + layout.column, row: cell.row * 4 + layout.row, x: x, y: y,
                           width: cell.width / 2, distance: distance, intensity: exp(-distance / decay), location: x / glow.width)
            return (layout.bit, dot)
        }
    }

    /// Signed distance from a point to the island's outline (bottom corners rounded, top edge off screen).
    /// Negative inside the island.
    public static func distance(x: Double, y: Double, glow: GlowGeometry, islandRadius: Double) -> Double {
        let left = glow.sideInset
        let right = glow.width - glow.sideInset
        let bottom = glow.height - glow.sideInset
        let islandHeight = bottom + glow.topOffset
        let radius = max(0, min(islandRadius, min(right - left, islandHeight) / 2))
        let cornerY = bottom - radius
        if y <= cornerY {
            if x < left { return left - x }
            if x > right { return x - right }
            return -min(x - left, right - x)
        }
        let cornerX = min(max(x, left + radius), right - radius)
        return ((x - cornerX) * (x - cornerX) + (y - cornerY) * (y - cornerY)).squareRoot() - radius
    }
}
