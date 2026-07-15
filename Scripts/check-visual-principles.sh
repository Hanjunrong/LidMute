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

for token in surfacePrimary surfaceSecondary surfaceTertiary primaryText secondaryText border; do
    grep -q "$token" "$theme_file" \
        || fail "Adaptive theme must define semantic token: $token"
done

grep -q "AmberVisualTheme.palette" "$content_view" \
    || fail "ContentView must consume the adaptive semantic theme palette"

grep -q "AmberVisualTheme.palette" "$repo_root/Sources/LidMuteApp/LiquidGlassControls.swift" \
    || fail "LiquidGlassControls must consume the adaptive semantic theme palette"

if grep -R -qF '.background(.white.opacity(' "$content_view" "$repo_root/Sources/LidMuteApp/LiquidGlassControls.swift"; then
    fail "Dashboard surfaces must use adaptive theme tokens instead of fixed white opacity"
fi

echo "PASS visual principle source checks"
