import Foundation

public enum AppearanceMode: String, Codable, Sendable, CaseIterable {
        case system
        case dark
        case light
}

/// How the notch glow is drawn.
public enum GlowStyle: String, Codable, Sendable, CaseIterable {
    /// The blurred band from the design.
    case blur
    /// A halftone grid: dots shrink as the glow fades.
    case dots
    /// The same grid drawn with ASCII characters ordered by density.
    case ascii
    /// Shade blocks ░▒▓ with a solid cell where the glow is strongest.
    case blocks
    /// Braille characters whose eight dots switch on by ordered dithering.
    case braille
    /// Ones and zeros dithered from the glow; zeros stay dim.
    case binary
}

/// What the dot and ASCII glow styles do while an agent is running.
public enum GlowEffect: String, Codable, Sendable, CaseIterable {
    /// Dots grow and shrink with the breath period and depth.
    case breathe
    /// The colour gradient drifts back and forth along the notch.
    case flow
    /// A bright band sweeps from left to right.
    case scan
    /// Brightness waves travel outward from the island.
    case ripple
    /// Cells twinkle with per-cell noise.
    case shimmer
    /// The glow grows out from the island's edge, holds, then fades.
    case boot
}

/// User-tunable settings. Every field has a default so older stored JSON still decodes.
public struct Settings: Hashable, Codable, Sendable {
    public static let glowSizeRange: ClosedRange<Double> = 0...20
    public static let glowGridPitchRange: ClosedRange<Double> = 4...16
    public static let glowGridSpreadRange: ClosedRange<Double> = 1...4
    public static let glowGridDensityRange: ClosedRange<Double> = 0.6...2

    public var breathSeconds: Double = 3
    /// 0…1. Glow opacity oscillates between `1 - amplitude` and 1 (times brightness).
    public var breathAmplitude: Double = 0.6
    public var glowRange: Double = 14
    public var glowBlur: Double = 8
    /// Keep the island's rim dense and fade outward with distance.
    public var glowOutwardOnly: Bool = true
    /// 0.2…1
    public var glowBrightness: Double = 0.9
    public var glowStyle: GlowStyle = .blur
    /// Grid spacing in points for the dot and ASCII styles. A third of the notch height, as in the design.
    public var glowGridPitch: Double = 10
    /// How far the grid glow reaches: its decay length in grid cells.
    public var glowGridSpread: Double = 2.4
    /// How much of its cell each dot or character fills; above 1 marks grow into their neighbours. The grid stays put.
    public var glowGridDensity: Double = 1
    public var glowEffect: GlowEffect = .breathe
    public var hoverDelayMs: Int = 400
    public var collapseDelayMs: Int = 200
    public var showResetCountdown: Bool = true
    public var showIslandQuota: Bool = true
    public var showIslandTokens: Bool = true
    public var showIslandSessions: Bool = true
    /// Agent vendors whose live status is excluded from presentation, relay and completion reminders.
    /// Collection, session history and token accounting are independent of this preference.
    public private(set) var disabledLiveStatusSources: Set<String> = []
    /// Querying GitHub Copilot quota reads the GitHub CLI sign-in, so it stays off until the user agrees.
    public var readCopilotQuota: Bool = false
    public var launchAtLogin: Bool = true
    public var showMenuBarIcon: Bool = true
    public var appearance: AppearanceMode = .system
    public var language: AppLanguage = .system

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case breathSeconds, breathAmplitude, glowRange, glowBlur, glowBrightness, glowOutwardOnly
        case glowStyle, glowGridPitch, glowGridSpread, glowGridDensity, glowEffect
        case hoverDelayMs, collapseDelayMs, showResetCountdown
        case showIslandQuota, showIslandTokens, showIslandSessions
        case disabledLiveStatusSources, readCopilotQuota
        case launchAtLogin, showMenuBarIcon, appearance, language
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        breathSeconds = try c.decodeIfPresent(Double.self, forKey: .breathSeconds) ?? d.breathSeconds
        breathAmplitude = try c.decodeIfPresent(Double.self, forKey: .breathAmplitude) ?? d.breathAmplitude
        glowRange = Self.clampGlowSize(try c.decodeIfPresent(Double.self, forKey: .glowRange) ?? d.glowRange)
        glowBlur = Self.clampGlowSize(try c.decodeIfPresent(Double.self, forKey: .glowBlur) ?? d.glowBlur)
        glowOutwardOnly = try c.decodeIfPresent(Bool.self, forKey: .glowOutwardOnly) ?? d.glowOutwardOnly
        glowBrightness = try c.decodeIfPresent(Double.self, forKey: .glowBrightness) ?? d.glowBrightness
        // A style saved by a newer build falls back to the blurred glow instead of failing the whole decode.
        glowStyle = (try? c.decodeIfPresent(GlowStyle.self, forKey: .glowStyle)) ?? d.glowStyle
        glowGridPitch = Self.clamp(try c.decodeIfPresent(Double.self, forKey: .glowGridPitch), to: Self.glowGridPitchRange, default: d.glowGridPitch)
        glowGridSpread = Self.clamp(try c.decodeIfPresent(Double.self, forKey: .glowGridSpread), to: Self.glowGridSpreadRange, default: d.glowGridSpread)
        glowGridDensity = Self.clamp(try c.decodeIfPresent(Double.self, forKey: .glowGridDensity), to: Self.glowGridDensityRange, default: d.glowGridDensity)
        glowEffect = (try? c.decodeIfPresent(GlowEffect.self, forKey: .glowEffect)) ?? d.glowEffect
        hoverDelayMs = try c.decodeIfPresent(Int.self, forKey: .hoverDelayMs) ?? d.hoverDelayMs
        collapseDelayMs = try c.decodeIfPresent(Int.self, forKey: .collapseDelayMs) ?? d.collapseDelayMs
        showResetCountdown = try c.decodeIfPresent(Bool.self, forKey: .showResetCountdown) ?? d.showResetCountdown
        showIslandQuota = try c.decodeIfPresent(Bool.self, forKey: .showIslandQuota) ?? d.showIslandQuota
        showIslandTokens = try c.decodeIfPresent(Bool.self, forKey: .showIslandTokens) ?? d.showIslandTokens
        showIslandSessions = try c.decodeIfPresent(Bool.self, forKey: .showIslandSessions) ?? d.showIslandSessions
        disabledLiveStatusSources = Set((try c.decodeIfPresent([String].self, forKey: .disabledLiveStatusSources) ?? []).map { $0.lowercased() })
        readCopilotQuota = try c.decodeIfPresent(Bool.self, forKey: .readCopilotQuota) ?? d.readCopilotQuota
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? d.launchAtLogin
        showMenuBarIcon = try c.decodeIfPresent(Bool.self, forKey: .showMenuBarIcon) ?? d.showMenuBarIcon
        appearance = try c.decodeIfPresent(AppearanceMode.self, forKey: .appearance) ?? d.appearance
        language = try c.decodeIfPresent(AppLanguage.self, forKey: .language) ?? d.language
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(breathSeconds, forKey: .breathSeconds)
        try c.encode(breathAmplitude, forKey: .breathAmplitude)
        try c.encode(glowRange, forKey: .glowRange)
        try c.encode(glowBlur, forKey: .glowBlur)
        try c.encode(glowBrightness, forKey: .glowBrightness)
        try c.encode(glowOutwardOnly, forKey: .glowOutwardOnly)
        try c.encode(glowStyle, forKey: .glowStyle)
        try c.encode(glowGridPitch, forKey: .glowGridPitch)
        try c.encode(glowGridSpread, forKey: .glowGridSpread)
        try c.encode(glowGridDensity, forKey: .glowGridDensity)
        try c.encode(glowEffect, forKey: .glowEffect)
        try c.encode(hoverDelayMs, forKey: .hoverDelayMs)
        try c.encode(collapseDelayMs, forKey: .collapseDelayMs)
        try c.encode(showResetCountdown, forKey: .showResetCountdown)
        try c.encode(showIslandQuota, forKey: .showIslandQuota)
        try c.encode(showIslandTokens, forKey: .showIslandTokens)
        try c.encode(showIslandSessions, forKey: .showIslandSessions)
        try c.encode(disabledLiveStatusSources.sorted(), forKey: .disabledLiveStatusSources)
        try c.encode(readCopilotQuota, forKey: .readCopilotQuota)
        try c.encode(launchAtLogin, forKey: .launchAtLogin)
        try c.encode(showMenuBarIcon, forKey: .showMenuBarIcon)
        try c.encode(appearance, forKey: .appearance)
        try c.encode(language, forKey: .language)
    }

    private static func clampGlowSize(_ value: Double) -> Double {
        min(glowSizeRange.upperBound, max(glowSizeRange.lowerBound, value))
    }

    private static func clamp(_ value: Double?, to range: ClosedRange<Double>, default fallback: Double) -> Double {
        guard let value, value.isFinite else { return fallback }
        return min(range.upperBound, max(range.lowerBound, value))
    }

    /// Functional update helper so call sites read as `settings.with { $0.glowRange = 20 }`.
    public func with(_ change: (inout Settings) -> Void) -> Settings {
        var copy = self
        change(&copy)
        return copy
    }

    public var hoverDelay: TimeInterval { Double(hoverDelayMs) / 1000 }
    public var collapseDelay: TimeInterval { Double(collapseDelayMs) / 1000 }

    public func liveStatusEnabled(for vendor: String) -> Bool {
        !disabledLiveStatusSources.contains(vendor.lowercased())
    }

    public mutating func setLiveStatus(for vendor: String, enabled: Bool) {
        if enabled { disabledLiveStatusSources.remove(vendor.lowercased()) }
        else { disabledLiveStatusSources.insert(vendor.lowercased()) }
    }
}
