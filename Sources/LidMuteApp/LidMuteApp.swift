import AppKit
import SwiftUI

@MainActor
final class LidMuteAppDelegate: NSObject, NSApplicationDelegate {
    let model = AppViewModel()
    private let presentationController = ApplicationPresentationController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.start()
        presentationController.applyLightweightMode(model.isLightweightModeEnabled)
    }

    func setLightweightModeEnabled(_ enabled: Bool) {
        model.setLightweightModeEnabled(enabled)
        presentationController.applyLightweightMode(enabled)
    }
}

@main
struct LidMuteApp: App {
    @NSApplicationDelegateAdaptor(LidMuteAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("LidMute") {
            ContentView(model: appDelegate.model)
        }
        .defaultSize(width: 1120, height: 680)

        MenuBarExtra {
            MenuBarMenu(model: appDelegate.model) { enabled in
                appDelegate.setLightweightModeEnabled(enabled)
            }
        } label: {
            MenuBarLabel(model: appDelegate.model)
        }
    }
}

private struct MenuBarLabel: View {
    @ObservedObject var model: AppViewModel

    var body: some View {
        Label("LidMute", systemImage: model.isEnabled ? "speaker.slash.fill" : "speaker")
    }
}

private struct MenuBarMenu: View {
    @ObservedObject var model: AppViewModel
    let setLightweightModeEnabled: (Bool) -> Void

    var body: some View {
        Button(model.isEnabled ? "关闭守卫" : "开启守卫") {
            model.setEnabled(!model.isEnabled)
        }
        Toggle(
            "轻量模式",
            isOn: Binding(
                get: { model.isLightweightModeEnabled },
                set: { enabled in
                    setLightweightModeEnabled(enabled)
                }
            )
        )
        Divider()
        Button("退出 LidMute") { NSApplication.shared.terminate(nil) }
    }
}
