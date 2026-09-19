import SwiftUI
import AgentHUDCore

struct GlowPane: View {
    let settings: SettingsStore
    let store: UsageStore
    let theme: Theme
    /// The selected screen's placement, so the preview shows the shape that screen actually wears.
    var placement: ScreenPlacement = .default(hasNotch: true)

    private var title: String {
        placement.mode == .logos
            ? L10n.text("背景光晕", "Backdrop glow")
            : L10n.text("灵动岛光晕", "Notch glow")
    }

    var body: some View {
        let current = settings.settings
        let grid = current.glowStyle != .blur
        SettingsSection(title: title, theme: theme) {
            SettingsPreview {
                Color.clear.frame(height: 112)
                    .overlay(alignment: .top) {
                        if placement.mode == .logos {
                            LogoQueuePreview(settings: settings, store: store, placement: placement)
                        } else {
                            GlowPreview(
                                appearance: store.glowAppearance(light: false), settings: current,
                                islandSize: CGSize(width: 240, height: 30), islandRadius: 13, previewsMotion: true
                            )
                        }
                    }
            }
            SettingRow(label: L10n.text("光晕样式", "Glow style")) {
                SelectionMenu(title: L10n.text("光晕样式", "Glow style"),
                              options: GlowStyle.allCases.map { SegmentOption(value: $0, label: $0.label) },
                              selection: settings.binding(\.glowStyle), theme: theme, width: 160)
            }
            SettingsDivider(theme: theme)
            SettingRow(label: L10n.text("动效", "Effect"),
                       subtitle: L10n.text("一直在动：工作时按工作周期，空闲时慢下来。", "Always in motion: the working period while an agent runs, slower when idle.")) {
                SelectionMenu(title: L10n.text("动效", "Effect"),
                              options: GlowEffect.allCases.map { SegmentOption(value: $0, label: $0.label) },
                              selection: settings.binding(\.glowEffect), theme: theme)
            }
            SettingsDivider(theme: theme)
            if grid {
                SliderRow(label: L10n.text("点距", "Grid pitch"), value: settings.binding(\.glowGridPitch), range: AgentHUDCore.Settings.glowGridPitchRange, step: 1, format: { "\(Int($0)) pt" }, theme: theme)
                SettingsDivider(theme: theme)
                SliderRow(label: L10n.text("密度", "Density"), value: settings.binding(\.glowGridDensity), range: AgentHUDCore.Settings.glowGridDensityRange, step: 0.05, format: { "\(Int(($0 * 100).rounded()))%" }, theme: theme)
                SettingsDivider(theme: theme)
                SliderRow(label: L10n.text("扩散", "Spread"), value: settings.binding(\.glowGridSpread), range: AgentHUDCore.Settings.glowGridSpreadRange, step: 0.1, format: { String(format: L10n.text("%.1f 格", "%.1f cells"), $0) }, theme: theme)
                SettingsDivider(theme: theme)
            }
            SliderRow(label: L10n.text("光晕亮度", "Brightness"), value: percentBinding(\.glowBrightness), range: 20...100, step: 5, format: { "\(Int($0))%" }, theme: theme)
            if !grid {
                SettingsDivider(theme: theme)
                SliderRow(label: L10n.text("光晕范围", "Glow range"), value: settings.binding(\.glowRange), range: AgentHUDCore.Settings.glowSizeRange, step: 1, format: { "\(Int($0)) px" }, theme: theme)
                SettingsDivider(theme: theme)
                SliderRow(label: L10n.text("羽化", "Feather"), value: settings.binding(\.glowBlur), range: AgentHUDCore.Settings.glowSizeRange, step: 1, format: { "\(Int($0)) px" }, theme: theme)
                SettingsDivider(theme: theme)
                SettingsToggleRow(
                    label: L10n.text("仅向外扩散", "Outward only"),
                    subtitle: L10n.text("贴近灵动岛的边缘更浓，向外逐渐变淡。", "Keep the rim defined and fade gently outward."),
                    isOn: settings.binding(\.glowOutwardOnly)
                )
            }
            let seconds: (Double) -> String = { String(format: L10n.text("%.1f 秒", "%.1f s"), $0) }
            // The period drives whichever effect is selected, not just breathing; only the depth is breathe's own.
            SettingsDivider(theme: theme)
            SliderRow(label: L10n.text("工作时周期", "Working period"), value: settings.binding(\.breathSeconds), range: 1...12, step: 0.5, format: seconds, theme: theme)
            SettingsDivider(theme: theme)
            SliderRow(label: L10n.text("空闲时周期", "Idle period"), value: settings.binding(\.idleBreathSeconds), range: 1...24, step: 0.5, format: seconds, theme: theme)
            if current.glowEffect == .breathe {
                SettingsDivider(theme: theme)
                SliderRow(label: L10n.text("呼吸幅度", "Breath depth"), value: percentBinding(\.breathAmplitude), range: 0...100, step: 5, format: { "\(Int($0))%" }, theme: theme)
            }
            Text(caption(grid: grid, effect: current.glowEffect))
                .font(.ui(11)).foregroundStyle(theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.bottom, 12)
        }
    }

    private func caption(grid: Bool, effect: GlowEffect) -> String {
        let density = grid ? L10n.text("密度决定点和字符占满格子的程度，调高后空隙更小，超过 100% 会互相重叠。", "Density sets how much of each cell a mark fills; raise it for smaller gaps, and past 100% marks overlap. ") : ""
        if !grid && effect == .breathe {
            return L10n.text("Agent 运行时自动呼吸，空闲时保持静态光晕。", "The glow breathes while an agent is running, and rests when it is idle.")
        }
        return density + L10n.text("上方预览会一直播放所选动效；灵动岛上只在 Agent 运行时播放。", "The preview always plays the selected effect; the notch plays it only while an agent is running.")
    }

    private func percentBinding(_ keyPath: WritableKeyPath<AgentHUDCore.Settings, Double>) -> Binding<Double> {
        Binding(
            get: { settings.settings[keyPath: keyPath] * 100 },
            set: { value in settings.update { $0[keyPath: keyPath] = value / 100 } }
        )
    }
}

private extension GlowStyle {
    var label: String {
        switch self {
        case .blur: L10n.text("柔光", "Soft")
        case .dots: L10n.text("点阵", "Dots")
        case .ascii: L10n.text("字符  .:-=+*#%@", "ASCII  .:-=+*#%@")
        case .blocks: L10n.text("色块  ░▒▓█", "Blocks  ░▒▓█")
        case .braille: L10n.text("盲文  ⠁⠃⠇⡇⣿", "Braille  ⠁⠃⠇⡇⣿")
        case .binary: L10n.text("二进制  0 1", "Binary  0 1")
        }
    }
}

private extension GlowEffect {
    var label: String {
        switch self {
        case .breathe: L10n.text("呼吸", "Breathe")
        case .flow: L10n.text("流光", "Flow")
        case .scan: L10n.text("扫描", "Scan")
        case .ripple: L10n.text("涟漪", "Ripple")
        case .shimmer: L10n.text("闪烁", "Shimmer")
        case .boot: L10n.text("启动", "Boot")
        }
    }
}

/// What a screen in logo mode looks like: the marks with the backdrop falling behind them. The curtain is
/// the same trick the real HUD uses — a flat lip run wider than the preview, clipped back to it, so the
/// field falls straight down instead of curling in at the ends.
struct LogoQueuePreview: View {
    let settings: SettingsStore
    let store: UsageStore
    let placement: ScreenPlacement
    /// The menu bar the preview pretends to sit in.
    private static let menuBar: CGFloat = 24

    var body: some View {
        let items = LogoQueueItem.queue(rows: store.rows.map { row in
            (vendor: row.agent.vendor,
             isWorking: store.sessions.contains { $0.agentId == row.agent.id && $0.endedAt == nil })
        })
        let config = LogoQueueConfig(items: items, placement: placement,
                                     settings: settings.settings, menuBarHeight: Self.menuBar)
        GeometryReader { proxy in
            let width = max(1, min(proxy.size.width, config.size.width + 48))
            ZStack(alignment: .top) {
                GlowPreview(
                    appearance: store.glowAppearance(light: false), settings: settings.settings,
                    islandSize: CGSize(width: width + 400, height: 2), islandRadius: 0, previewsMotion: true
                )
                .frame(width: width, alignment: .center)
                .clipped()
                LogoQueueView(config: config, light: false)
                    .frame(width: width, height: max(Self.menuBar, config.logo))
            }
            .frame(width: proxy.size.width, alignment: .center)
        }
    }
}
