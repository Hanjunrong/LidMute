# Simulation Button Label Layout

## Goal

Ensure the `模拟合盖` and `模拟开盖` labels remain fully visible in the Control Center Glass interface, including at the app's supported compact window width.

## Design

- Keep both existing capsule buttons, symbols, colors, actions, disabled states, and accessibility values.
- Apply the existing compact system typography to each label.
- Keep each label on one line and give its text intrinsic horizontal priority so SwiftUI does not replace characters with an ellipsis.
- Tighten only the symbol-to-text spacing as needed; do not reduce the button hit target or change the surrounding `SimulationCard` layout.
- Preserve Dynamic Type behavior: the label may request its intrinsic width rather than clipping or truncating.

## Scope

The implementation is limited to the two labels in `SimulationCard`. It does not change simulation behavior, the reset control, other cards, or the browser demo.

## Verification

- Add or update the visual-principles check so both labels are required to opt out of truncation.
- Run the focused visual-principles check.
- Build the app to catch SwiftUI compilation errors.
