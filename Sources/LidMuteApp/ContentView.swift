import SwiftUI
import LidMuteCore

struct ContentView: View {
    @ObservedObject var model: AppViewModel

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [.orange.opacity(0.42), .cyan.opacity(0.28), .blue.opacity(0.26), .indigo.opacity(0.28)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            Circle()
                .fill(.orange.opacity(0.24))
                .frame(width: 280, height: 280)
                .blur(radius: 65)
                .offset(x: -240, y: -260)
            Circle()
                .fill(.cyan.opacity(0.2))
                .frame(width: 340, height: 340)
                .blur(radius: 75)
                .offset(x: 250, y: 260)

            glassSurface {
                VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("LidMute")
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                        Text("合盖监控系统外放守卫")
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
                .glassCard()

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label("息屏夜间静音", systemImage: model.isNightProtectionActive ? "moon.stars.fill" : "moon.stars")
                            .font(.headline)
                        Spacer()
                        Toggle("", isOn: $model.nightScheduleEnabled)
                            .labelsHidden()
                    }
                    HStack(spacing: 10) {
                        TextField("开始 HH:mm", text: $model.nightStartText)
                            .textFieldStyle(.roundedBorder)
                        Text("至")
                            .foregroundStyle(.secondary)
                        TextField("结束 HH:mm", text: $model.nightEndText)
                            .textFieldStyle(.roundedBorder)
                        Button("应用") { model.applyNightSchedule() }
                            .buttonStyle(.borderedProminent)
                    }
                    HStack {
                        Text(model.nightScheduleStatus)
                        Spacer()
                        Text(model.isDisplaySleeping ? "当前：息屏" : "当前：亮屏")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .glassCard()

                HStack(spacing: 12) {
                    SimulationButton(
                        title: "模拟合盖",
                        systemImage: "laptopcomputer",
                        isSelected: model.simulatedLidState == .closed,
                        tint: .orange,
                        action: model.simulateLidClosed
                    )
                    SimulationButton(
                        title: "模拟开盖",
                        systemImage: "laptopcomputer.and.arrow.up",
                        isSelected: model.simulatedLidState == .opened,
                        tint: .cyan,
                        action: model.simulateLidOpened
                    )
                    Button("清空记录") { model.clearLog() }
                    Button("重置模拟状态") { model.resetSimulationState() }
                    Spacer()
                    Text(model.chromeBridgeStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.bordered)

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label("当前声音", systemImage: "waveform")
                            .font(.headline)
                        Spacer()
                        Text("CoreAudio 实时")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if model.currentAudioProcesses.isEmpty {
                        Text("当前没有检测到输出声音的程序")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.currentAudioProcesses, id: \.pid) { process in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(process.name)
                                        .font(.subheadline.weight(.semibold))
                                    Spacer()
                                    Text("PID \(process.pid)")
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                Text([process.bundleID, process.executablePath].compactMap { $0 }.joined(separator: "  |  "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    Divider().opacity(0.45)
                    HStack(spacing: 12) {
                        Button { model.sendMediaCommand(.previous) } label: {
                            Label("上一首", systemImage: "backward.fill")
                        }
                        Button { model.sendMediaCommand(.playPause) } label: {
                            Label("暂停/开始", systemImage: "playpause.fill")
                        }
                        Button { model.sendMediaCommand(.next) } label: {
                            Label("下一首", systemImage: "forward.fill")
                        }
                        Spacer()
                        Text(model.mediaStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .buttonStyle(.bordered)
                }
                .glassCard()

                Text("活动记录")
                    .font(.headline)
                List(model.events) { event in
                    EventRow(event: event)
                }
                .scrollContentBackground(.hidden)
                .glassCard()
                }
                .padding(22)
            }
        }
        .frame(minWidth: 760, minHeight: 840)
    }

    @ViewBuilder
    private func glassSurface<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        if #available(macOS 26.0, *) {
            content()
                .glassEffect(.regular.tint(.white.opacity(0.08)), in: .rect(cornerRadius: 30))
        } else {
            content()
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous).stroke(.white.opacity(0.35), lineWidth: 1))
        }
    }
}

private extension View {
    @ViewBuilder
    func glassCard() -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: 22))
        } else {
            self
                .padding(16)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(.white.opacity(0.35), lineWidth: 1))
        }
    }
}

private struct SimulationButton: View {
    let title: String
    let systemImage: String
    let isSelected: Bool
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: isSelected ? "checkmark.circle.fill" : systemImage)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 13)
                .padding(.vertical, 8)
                .foregroundStyle(isSelected ? .white : .primary.opacity(0.68))
                .background(.ultraThinMaterial, in: Capsule())
                .background((isSelected ? tint.opacity(0.76) : Color.gray.opacity(0.16)), in: Capsule())
                .overlay(Capsule().stroke(isSelected ? tint.opacity(0.95) : .white.opacity(0.3), lineWidth: 1))
                .shadow(color: isSelected ? tint.opacity(0.42) : .clear, radius: 9, y: 3)
        }
        .buttonStyle(.plain)
        .disabled(isSelected)
        .accessibilityValue(isSelected ? "已选择" : "未选择")
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
