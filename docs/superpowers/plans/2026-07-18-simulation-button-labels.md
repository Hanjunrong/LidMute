# Simulation Button Labels Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep the `模拟合盖` and `模拟开盖` button labels fully visible without changing their behavior or Control Center Glass styling.

**Architecture:** Add a small private SwiftUI label view owned by `SimulationCard`, then use it for both actions. Extend the existing source-contract script so truncation prevention remains regression-tested.

**Tech Stack:** Swift 6, SwiftUI for macOS, Bash source-contract checks, Swift Package Manager

## Global Constraints

- Keep existing symbols, colors, actions, disabled states, accessibility values, and button hit targets.
- Keep the text on one line and prevent ellipsis truncation.
- Limit the production change to the two simulation labels and their private presentation helper.
- Do not modify the browser demo.

---

### Task 1: Non-truncating simulation action labels

**Files:**
- Modify: `Scripts/check-visual-principles.sh`
- Modify: `Sources/LidMuteApp/ContentView.swift:300-350`

**Interfaces:**
- Consumes: `ControlCenterTypography.compactCaption` and the existing SF Symbol names.
- Produces: private `SimulationActionLabel(title:systemImage:) -> View` used by both simulation buttons.

- [ ] **Step 1: Write the failing source-contract check**

Add checks that require `SimulationActionLabel`, `ControlCenterTypography.compactCaption`, `.lineLimit(1)`, and `.fixedSize(horizontal: true, vertical: false)` in `ContentView.swift`.

- [ ] **Step 2: Run the check to verify it fails**

Run: `bash Scripts/check-visual-principles.sh`

Expected: exit 1 with `Simulation controls must use a dedicated compact action label`.

- [ ] **Step 3: Implement the minimal SwiftUI label**

Add this private view near `SimulationCard`:

```swift
private struct SimulationActionLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
            Text(title)
                .font(ControlCenterTypography.compactCaption)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
    }
}
```

Replace each `Label` with `SimulationActionLabel`, preserving the current title and conditional SF Symbol expression.

- [ ] **Step 4: Run focused and build verification**

Run: `bash Scripts/check-visual-principles.sh`

Expected: `PASS visual principle source checks`.

Run: `swift build --disable-sandbox`

Expected: `Build complete!` with exit code 0.

- [ ] **Step 5: Review and commit**

Run: `git diff --check && git diff -- Scripts/check-visual-principles.sh Sources/LidMuteApp/ContentView.swift`

Commit:

```bash
git add Scripts/check-visual-principles.sh Sources/LidMuteApp/ContentView.swift docs/superpowers/plans/2026-07-18-simulation-button-labels.md
git commit -m "fix: keep simulation labels visible"
```
