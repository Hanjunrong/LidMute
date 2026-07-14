import AppKit

@MainActor
final class ApplicationPresentationController {
    func applyLightweightMode(_ enabled: Bool) {
        if enabled {
            NSApp.setActivationPolicy(.accessory)
            NSApp.hide(nil)
            return
        }

        NSApp.setActivationPolicy(.regular)
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where !window.isVisible {
            window.makeKeyAndOrderFront(nil)
        }
    }
}
