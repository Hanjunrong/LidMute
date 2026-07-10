import SwiftUI
import LidMuteCore

struct ContentView: View {
    @ObservedObject var model: AppViewModel

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [.orange.opacity(0.38), .cyan.opacity(0.24), .indigo.opacity(0.28)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("LidMute")
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                        Text("合盖外放守卫")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(model.isEnabled ? "关闭守卫" : "开启守卫") {
                        model.setEnabled(!model.isEnabled)
                    }
                    .buttonStyle(.borderedProminent)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Label(model.statusText, systemImage: model.isEnabled ? "speaker.slash.circle.fill" : "shield.lefthalf.filled")
                        .font(.headline)
                    Text("仅对默认内建音频输出执行静音；外接输出不会被修改。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(18)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(.white.opacity(0.4), lineWidth: 1))

                HStack(spacing: 12) {
                    Button("模拟合盖") { model.simulateLidClosed() }
                    Button("模拟开盖") { model.simulateLidOpened() }
                    Button("清空记录") { model.clearLog() }
                    Spacer()
                    Text(model.chromeBridgeStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.bordered)

                Text("活动记录")
                    .font(.headline)
                List(model.events) { event in
                    EventRow(event: event)
                }
                .scrollContentBackground(.hidden)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            }
            .padding(24)
        }
        .frame(minWidth: 620, minHeight: 650)
    }
}

private struct EventRow: View {
    let event: LidMuteEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(event.kind.rawValue)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tint)
                Spacer()
                Text(event.timestamp, style: .time)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(event.detail)
                .font(.subheadline)
            if let tab = event.chromeTab {
                Text("\(tab.title) | \(tab.url)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 5)
        .listRowBackground(Color.white.opacity(0.16))
    }
}
