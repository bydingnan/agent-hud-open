# Brand assets

## Overview

Which client logos the application bundles, where each one came from, how it is rendered, and under which terms. Logos are loaded from the application's resource bundle; no network request is made at runtime.

## Lobe Icons

Claude, OpenAI (shown as ChatGPT), Antigravity, DeepSeek and Grok come from [Lobe Icons](https://github.com/lobehub/lobe-icons), package `@lobehub/icons-static-png` version `1.97.0`.

| Bundled file | Original file in the package |
| --- | --- |
| `claude.png` | `light/claude-color.png` |
| `chatgpt.png` | `light/openai.png` |
| `antigravity.png` | `light/antigravity-color.png` |
| `deepseek.png` | `light/deepseek-color.png` |
| `grok.png` | `light/grok.png` |

The PNG files are unchanged (640 × 640); only the names differ: the `-color` suffix is dropped and `openai.png` is stored as `chatgpt.png`. Codex rows reuse the ChatGPT artwork under their own name. Claude, Antigravity and DeepSeek keep their source colors; the OpenAI mark is stored as shipped and tinted green (`#10A37F`) at render time for ChatGPT; Grok's monochrome mark is rendered as a template image, so it follows the foreground color in light and dark appearance. The package's MIT license is bundled as `LobeIcons-LICENSE.txt`.

## Cursor, OpenCode, Kimi, GLM and Pi

These five use the clients' official artwork instead of SF Symbols.

| Client | Source | Bundled file | Rendering |
| --- | --- | --- | --- |
| Cursor | [Official brand assets](https://cursor.com/brand), `General Logos/Cube/SVG/CUBE_2D_DARK.svg` in the downloadable archive | `cursor.png` | Monochrome template |
| OpenCode / OpenCode Go | [Official brand page](https://opencode.ai/brand); [square logos at commit 830d5eb](https://github.com/anomalyco/opencode/tree/830d5eb5354874105cc31599635a80c1662609e8/packages/console/app/src/asset/brand) | `opencode.png`, `opencode-dark.png` | Original artwork; the light or dark file is chosen by the current appearance |
| Kimi | [Official branding guide](https://moonshotai.github.io/Branding-Guide/), `scenarios/04-k-only/k-only-color.svg` | `kimi.png` | Monochrome template |
| GLM | [Z.ai](https://chat.z.ai/) linked [brand icon](https://z-cdn.chatglm.cn/z-ai/static/logo.svg) | `glm.png` | Original artwork |
| Pi | [Official press kit](https://pi.dev/press-kit), [primary logo](https://pi.dev/logo-auto.svg) | `pi.png` | Monochrome template |

The bundled files are 256 × 256 transparent PNG renders of those SVGs. Pi's excess transparent canvas is trimmed before fitting, without changing the mark's geometry. The original SVGs are not distributed in this repository.

## Rendering rules

Every logo is drawn into a 16 × 16 point image. Grok, Cursor, Kimi and Pi are template images (monochrome, foreground-colored); Claude, ChatGPT (tinted), Antigravity, DeepSeek, GLM and OpenCode are drawn as original images. SwiftUI views and the status-item menu use the same images.

## Licenses and trademarks

Lobe Icons are MIT-licensed (`LobeIcons-LICENSE.txt`). Brand names and marks belong to their respective owners and are used only to identify the corresponding client. Provider protocol references are listed separately in `THIRD_PARTY_NOTICES.txt`.

## Code map

| Concept | Code |
| --- | --- |
| Bundled logos and license files | `Sources/AgentHUDDesktop/Resources/` |
| Resource lookup and logo drawing | `Sources/AgentHUDDesktop/Components/AppResources.swift`, `AgentLogo.swift` |

## Related

[architecture.md](architecture.md#design-invariants) resources and notices · [../THIRD_PARTY_NOTICES.txt](../THIRD_PARTY_NOTICES.txt)
