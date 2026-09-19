import Foundation

/// How one screen presents the HUD.
public enum HUDMode: String, Codable, Sendable, CaseIterable {
    /// The island: the notch itself, or a bar standing in for one on displays without.
    case notch
    /// A queue of the agents' own logos, parked on a screen edge, with the glow behind them as a backdrop.
    case logos
}

/// The screen edge a HUD is parked on. It runs along that edge and opens inward.
public enum HUDEdge: String, Codable, Sendable, CaseIterable {
    case top, right, bottom, left

    public var isHorizontal: Bool { self == .top || self == .bottom }

    /// Unit vector pointing into the screen from this edge.
    public var inward: (x: Double, y: Double) {
        switch self {
        case .top: return (0, -1)
        case .bottom: return (0, 1)
        case .left: return (1, 0)
        case .right: return (-1, 0)
        }
    }
}

/// One screen's HUD. Everything here is per screen: two displays can run different modes, sit on
/// different edges and size their logos differently. The glow style is not — it is the HUD's material,
/// shared by every screen; what changes per screen is the shape it is drawn around.
public struct ScreenPlacement: Hashable, Codable, Sendable {
    /// Logo height as a share of the menu bar height, so the default fits the bar on any display.
    public static let logoScaleRange: ClosedRange<Double> = 0.5...2.5
    /// Gap between logos, as a share of the logo's height.
    public static let gapScaleRange: ClosedRange<Double> = 0.1...1
    public var mode: HUDMode
    public var edge: HUDEdge
    /// The queue's centre along its edge, as a fraction of that edge's length, so it survives a
    /// resolution change.
    public var offset: Double
    public var logoScale: Double
    public var gapScale: Double

    public init(
        mode: HUDMode = .logos,
        edge: HUDEdge = .top,
        offset: Double = 0.5,
        logoScale: Double = 0.82,
        gapScale: Double = 0.4
    ) {
        self.mode = mode
        self.edge = edge
        self.offset = Self.clamp(offset, to: 0...1)
        self.logoScale = Self.clamp(logoScale, to: Self.logoScaleRange)
        self.gapScale = Self.clamp(gapScale, to: Self.gapScaleRange)
    }

    /// A display's starting point: a notched screen keeps its island, anything else shows the queue.
    public static func `default`(hasNotch: Bool) -> ScreenPlacement {
        ScreenPlacement(mode: hasNotch ? .notch : .logos)
    }

    private static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(range.upperBound, max(range.lowerBound, value.isFinite ? value : range.lowerBound))
    }

    private enum CodingKeys: String, CodingKey {
        case mode, edge, offset, logoScale, gapScale
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ScreenPlacement()
        self.init(
            mode: (try? c.decodeIfPresent(HUDMode.self, forKey: .mode)) ?? d.mode,
            edge: (try? c.decodeIfPresent(HUDEdge.self, forKey: .edge)) ?? d.edge,
            offset: try c.decodeIfPresent(Double.self, forKey: .offset) ?? d.offset,
            logoScale: try c.decodeIfPresent(Double.self, forKey: .logoScale) ?? d.logoScale,
            gapScale: try c.decodeIfPresent(Double.self, forKey: .gapScale) ?? d.gapScale
        )
    }
}
