import AppKit
import ServiceManagement

@MainActor
final class ApplicationPresentationController {
    private let isLoginItemEnabled: () -> Bool
    private let presentLoginItemPrompt: @MainActor () -> Bool
    private let registerLoginItem: () throws -> Void
    private let openLoginItemSettings: () -> Void

    init(
        isLoginItemEnabled: @escaping () -> Bool = {
            SMAppService.mainApp.status == .enabled
        },
        presentLoginItemPrompt: @escaping @MainActor () -> Bool = {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "启用登录时打开"
            alert.informativeText = "LidMute 尚未在 macOS 登录项中启用。请在系统设置中添加或启用 LidMute，以便登录后自动启动合盖保护。"
            alert.addButton(withTitle: "注册开机自启动")
            alert.addButton(withTitle: "稍后")
            NSApp.activate(ignoringOtherApps: true)
            alert.window.makeKeyAndOrderFront(nil)
            defer {
                // Explicitly tear down the modal window. On some launch-time
                // activation paths runModal ends the session but leaves the
                // NSAlert window ordered on screen.
                alert.window.orderOut(nil)
                alert.window.close()
            }
            return alert.runModal() == .alertFirstButtonReturn
        },
        registerLoginItem: @escaping () throws -> Void = {
            try SMAppService.mainApp.register()
        },
        openLoginItemSettings: @escaping () -> Void = {
            SMAppService.openSystemSettingsLoginItems()
        }
    ) {
        self.isLoginItemEnabled = isLoginItemEnabled
        self.presentLoginItemPrompt = presentLoginItemPrompt
        self.registerLoginItem = registerLoginItem
        self.openLoginItemSettings = openLoginItemSettings
    }

    func promptForLoginItemRegistrationIfNeeded() {
        guard !isLoginItemEnabled(), presentLoginItemPrompt() else { return }
        do {
            try registerLoginItem()
        } catch {
            openLoginItemSettings()
        }
    }

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
