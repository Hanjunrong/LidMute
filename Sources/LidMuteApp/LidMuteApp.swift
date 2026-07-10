import SwiftUI

@main
struct LidMuteApp: App {
    @StateObject private var model = AppViewModel()

    var body: some Scene {
        WindowGroup("LidMute") {
            ContentView(model: model)
                .task { model.start() }
        }
        MenuBarExtra("LidMute", systemImage: model.isEnabled ? "speaker.slash.fill" : "speaker") {
            Button(model.isEnabled ? "关闭合盖监控系统外放守卫" : "开启合盖监控系统外放守卫") {
                model.setEnabled(!model.isEnabled)
            }
            Divider()
            Button("模拟合盖", action: model.simulateLidClosed)
                .disabled(model.simulatedLidState == .closed)
            Button("模拟开盖", action: model.simulateLidOpened)
                .disabled(model.simulatedLidState == .opened)
            Divider()
            Button("退出 LidMute") { NSApplication.shared.terminate(nil) }
        }
    }
}
