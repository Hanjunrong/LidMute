#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
content_view="$repo_root/Sources/LidMuteApp/ContentView.swift"
theme_file="$repo_root/Sources/LidMuteApp/AmberVisualTheme.swift"
controls_file="$repo_root/Sources/LidMuteApp/LiquidGlassControls.swift"

fail() {
    echo "FAIL visual principle: $*" >&2
    exit 1
}

grep -q "VisualLayoutMetrics.cardSpacing" "$content_view" \
    || fail "ContentView must use shared zero-spacing layout metrics for card adjacency"

grep -q "VisualLayoutMetrics.timelineDefaultViewportHeight" "$content_view" \
    || fail "ActivityTimeline must clamp its default viewport to exactly three full rows"

grep -q "VisualLayoutMetrics.timelineViewportHeight" "$content_view" \
    || fail "ActivityTimeline must be the only card that consumes extra window height"

if grep -q "Divider().opacity(0.22)" "$content_view"; then
    fail "Timeline dividers must not add height that exposes a partial fourth row"
fi

if grep -q "HStack(alignment: \\.bottom" "$content_view"; then
    fail "Middle card row must not bottom-align uneven columns and create local empty bands"
fi

grep -q "TightCardDeck" "$theme_file" \
    || fail "Card decks must provide a continuous backing so rounded adjacent cards have no visible cracks"

grep -q "enum AuroraCardRole" "$theme_file" \
    || fail "Aurora cards must expose semantic surface roles"

grep -q "struct AuroraSymbolTile" "$theme_file" \
    || fail "Aurora iconography must use the shared layered symbol tile"

grep -q "func amberGlassCard" "$theme_file" \
    && grep -q "role: AuroraCardRole" "$theme_file" \
    || fail "Aurora cards must require an explicit semantic role"

if grep -q "LinearGradient\|RadialGradient\|AngularGradient\|\.blur(" "$theme_file"; then
    fail "macOS 26 surfaces must not simulate Liquid Glass with gradients or blur"
fi

if grep -qF 'Color.black.opacity(0.22)' "$theme_file"; then
    fail "Card decks must not fall back to the obsolete flat black fill"
fi

for token in surfacePrimary surfaceSecondary surfaceTertiary primaryText secondaryText border; do
    grep -q "$token" "$theme_file" \
        || fail "Adaptive theme must define semantic token: $token"
done

grep -q "AmberVisualTheme.palette" "$content_view" \
    || fail "ContentView must consume the adaptive semantic theme palette"

grep -q "enum ControlCenterTypography" "$theme_file" \
    || fail "Control Center Glass must centralize the system typography hierarchy"

grep -q "ControlCenterTypography.heroTitle" "$content_view" \
    || fail "Hero typography must consume the shared Control Center title token"

grep -q "struct SimulationActionLabel" "$content_view" \
    || fail "Simulation controls must use a dedicated compact action label"

grep -qF '.font(ControlCenterTypography.compactCaption)' "$content_view" \
    && grep -qF '.lineLimit(1)' "$content_view" \
    && grep -qF '.fixedSize(horizontal: true, vertical: false)' "$content_view" \
    || fail "Simulation action labels must remain compact, single-line, and non-truncating"

for role in hero standard media timeline; do
    grep -q "amberGlassCard(role: \.$role" "$content_view" \
        || fail "ContentView must assign the Aurora card role: $role"
done

grep -q "AuroraSymbolTile(" "$content_view" \
    || fail "Dashboard icons must use the shared Aurora symbol tile"

if grep -qF '.fill(AmberVisualTheme.amber.opacity(0.18))' "$content_view"; then
    fail "Header icon must not use the obsolete flat amber tile"
fi

grep -q "AmberVisualTheme.palette" "$repo_root/Sources/LidMuteApp/LiquidGlassControls.swift" \
    || fail "LiquidGlassControls must consume the adaptive semantic theme palette"

grep -q "PrimitiveButtonStyle" "$controls_file" \
    || fail "Liquid Glass controls must delegate interaction to native primitive button styles"

grep -qF '.buttonStyle(.glass)' "$controls_file" \
    || fail "Standard macOS 26 controls must use the native glass button style"

grep -qF '.buttonStyle(.glassProminent)' "$controls_file" \
    || fail "Emphasized macOS 26 controls must use the native prominent glass button style"

grep -qF '.buttonStyle(.glass(.regular.tint(tint)))' "$controls_file" \
    || fail "Tinted macOS 26 controls must use the native tinted glass button style"

grep -q "GlassEffectContainer(spacing: spacing)" "$controls_file" \
    || fail "Related glass controls must support native GlassEffectContainer grouping"

grep -qF '.background(.regularMaterial' "$controls_file" \
    || fail "Pre-macOS 26 controls must use the standard Material fallback"

if grep -q "LinearGradient" "$controls_file"; then
    fail "Liquid Glass buttons must not draw simulated gradient chrome"
fi

if grep -qF '.interactive()' "$controls_file"; then
    fail "macOS glass buttons must rely on their native button style interaction"
fi

if grep -q "AuroraControlChrome\|IconInteractionModifier" "$controls_file"; then
    fail "Liquid Glass buttons must not stack custom chrome or press effects over native glass"
fi

grep -qF '#Preview {' "$content_view" \
    || fail "The native Liquid Glass interface must include a SwiftUI preview"

icon_renderer="$repo_root/Scripts/render-app-icon.swift"
grep -qF '"shield.fill"' "$icon_renderer" \
    || fail "App icon must use the approved guard shield symbol"
grep -qF '"speaker.slash.fill"' "$icon_renderer" \
    || fail "App icon must use the approved muted-speaker symbol"
if grep -qF 'apple.logo' "$icon_renderer"; then
    fail "App icon must not depend on the obsolete Apple trademark detail"
fi

if grep -R -qF '.background(.white.opacity(' "$content_view" "$repo_root/Sources/LidMuteApp/LiquidGlassControls.swift"; then
    fail "Dashboard surfaces must use adaptive theme tokens instead of fixed white opacity"
fi

echo "PASS visual principle source checks"
