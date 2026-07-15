#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
content_view="$repo_root/Sources/LidMuteApp/ContentView.swift"
theme_file="$repo_root/Sources/LidMuteApp/AmberVisualTheme.swift"

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

grep -q "LinearGradient" "$theme_file" \
    || fail "Aurora surfaces must include gradient depth"

if grep -qF 'Color.black.opacity(0.22)' "$theme_file"; then
    fail "Card decks must not fall back to the obsolete flat black fill"
fi

for token in surfacePrimary surfaceSecondary surfaceTertiary primaryText secondaryText border; do
    grep -q "$token" "$theme_file" \
        || fail "Adaptive theme must define semantic token: $token"
done

grep -q "AmberVisualTheme.palette" "$content_view" \
    || fail "ContentView must consume the adaptive semantic theme palette"

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

controls_file="$repo_root/Sources/LidMuteApp/LiquidGlassControls.swift"
grep -q "struct AuroraControlChrome" "$controls_file" \
    || fail "Liquid Glass controls must share Aurora optical chrome"

interactive_count="$(grep -oF '.interactive()' "$controls_file" | wc -l | tr -d ' ')"
[[ "$interactive_count" -ge 2 ]] \
    || fail "Native Liquid Glass button paths must remain interactive"

if grep -R -qF '.background(.white.opacity(' "$content_view" "$repo_root/Sources/LidMuteApp/LiquidGlassControls.swift"; then
    fail "Dashboard surfaces must use adaptive theme tokens instead of fixed white opacity"
fi

echo "PASS visual principle source checks"
