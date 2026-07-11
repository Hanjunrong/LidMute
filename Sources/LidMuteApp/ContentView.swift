import SwiftUI
import LidMuteCore

struct ContentView: View {
    @ObservedObject var model: AppViewModel

    var body: some View {
        ZStack {
            AmberAtmosphere()
                .ignoresSafeArea()

            VStack(spacing: 16) {
                HeaderBar(model: model)
                GuardHero(model: model)

                HStack(alignment: .top, spacing: 16) {
                    AutomationCard(model: model)
                        .frame(maxWidth: .infinity)
                    NowPlayingCard(model: model)
                        .frame(maxWidth: .infinity)
                }
                .frame(height: 210)

                SimulationCard(model: model)

                ActivityTimeline(model: model)
                    .frame(maxHeight: .infinity)
            }
            .padding(22)
        }
        .frame(minWidth: 900, minHeight: 780)
    }
}

private struct HeaderBar: View {
    @ObservedObject var model: AppViewModel

    var body: some View {
        HStack(spacing: 13) {
            ZStack {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(AmberVisualTheme.amber.opacity(0.18))
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 23, weight: .semibold))
                    .foregroundStyle(AmberVisualTheme.amber)
            }
            .frame(width: 46, height: 46)

            VStack(alignment: .leading, spacing: 1) {
                Text("LidMute")
                    .font(.system(size: 25, weight: .heavy, design: .rounded))
                Text("合盖监控系统外放守卫")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 8) {
                Circle()
                    .fill(model.chromeBridgeStatus.contains("已接收") ? AmberVisualTheme.seaGlass : Color.secondary.opacity(0.45))
                    .frame(width: 7, height: 7)
                Text(model.chromeBridgeStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(.white.opacity(0.09), in: Capsule())
        }
        .padding(.horizontal, 4)
    }
}

private struct GuardHero: View {
    @ObservedObject var model: AppViewModel

    var body: some View {
        HStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 9) {
                Label(model.isEnabled ? "守卫已开启" : "守卫未开启", systemImage: model.isEnabled ? "shield.fill" : "shield.slash")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(model.isEnabled ? AmberVisualTheme.amber : .secondary)

                Text(heroTitle)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .tracking(-0.4)

                Text(heroSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    MetricPill(
                        title: model.isDisplaySleeping ? "息屏" : "亮屏",
                        systemImage: model.isDisplaySleeping ? "display.trianglebadge.exclamationmark" : "display",
                        tint: AmberVisualTheme.mistBlue
                    )
                    MetricPill(
                        title: model.isNightProtectionActive ? "夜间保护中" : "夜间策略待命",
                        systemImage: model.isNightProtectionActive ? "moon.stars.fill" : "moon.stars",
                        tint: AmberVisualTheme.seaGlass
                    )
                    MetricPill(
                        title: model.currentAudioProcesses.isEmpty ? "无活动音频" : "\(model.currentAudioProcesses.count) 个音频进程",
                        systemImage: "waveform",
                        tint: AmberVisualTheme.amber
                    )
                }
            }

            Spacer(minLength: 12)

            Button {
                model.setEnabled(!model.isEnabled)
            } label: {
                Label(model.isEnabled ? "关闭守卫" : "开启守卫", systemImage: model.isEnabled ? "power" : "shield.fill")
            }
            .buttonStyle(
                LiquidGlassButtonStyle(
                    tint: AmberVisualTheme.amber,
                    isEmphasized: model.isEnabled,
                    shape: .capsule
                )
            )
        }
        .amberGlassCard(padding: 22, cornerRadius: 28)
    }

    private var heroTitle: String {
        if !model.isEnabled { return "安静由你决定" }
        if model.isNightProtectionActive { return "夜间模式正在保护外放" }
        if model.statusText.contains("正在保护") { return "外放安静，一切正常" }
        return "等待合盖或夜间息屏"
    }

    private var heroSubtitle: String {
        model.isEnabled
            ? "只控制 Mac 内建扬声器，耳机与外接音频不会被修改。"
            : "开启后，只有合盖或夜间息屏策略会触发静音。"
    }
}

private struct MetricPill: View {
    let title: String
    let systemImage: String
    let tint: Color

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(tint.opacity(0.09), in: Capsule())
            .overlay(Capsule().stroke(tint.opacity(0.20), lineWidth: 0.8))
    }
}

private struct AutomationCard: View {
    @ObservedObject var model: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                CardTitle(title: "自动保护", subtitle: "合盖与夜间策略", systemImage: "sparkles")
                Spacer()
                Toggle(
                    "",
                    isOn: Binding(
                        get: { model.nightScheduleEnabled },
                        set: { model.setNightScheduleEnabled($0) }
                    )
                )
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(AmberVisualTheme.amber)
                    .accessibilityLabel("息屏夜间静音")
                    .accessibilityValue(model.nightScheduleEnabled ? "已开启" : "已关闭")
                    .disabled(!model.isEnabled)
            }

            HStack(spacing: 9) {
                TextField("00:00", text: $model.nightStartText)
                    .textFieldStyle(.plain)
                    .font(.body.monospacedDigit().weight(.semibold))
                    .padding(.horizontal, 11)
                    .padding(.vertical, 8)
                    .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(.white.opacity(0.18)))
                    .onChange(of: model.nightStartText) { _, _ in model.nightScheduleTextChanged() }
                    .disabled(!model.isEnabled)

                Image(systemName: "arrow.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)

                TextField("08:00", text: $model.nightEndText)
                    .textFieldStyle(.plain)
                    .font(.body.monospacedDigit().weight(.semibold))
                    .padding(.horizontal, 11)
                    .padding(.vertical, 8)
                    .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(.white.opacity(0.18)))
                    .onChange(of: model.nightEndText) { _, _ in model.nightScheduleTextChanged() }
                    .disabled(!model.isEnabled)
            }

            Text("\(model.nightScheduleStatus) · \(model.isDisplaySleeping ? "当前息屏" : "当前亮屏")")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

        }
        .opacity(model.isEnabled ? 1 : 0.62)
        .amberGlassCard()
    }
}

private struct SimulationCard: View {
    @ObservedObject var model: AppViewModel

    var body: some View {
        HStack(spacing: 16) {
            CardTitle(title: "模拟测试", subtitle: "独立验证合盖状态", systemImage: "testtube.2")

            Spacer()

            HStack(spacing: 9) {
                Button {
                    model.simulateLidClosed()
                } label: {
                    Label(
                        "模拟合盖",
                        systemImage: model.simulatedLidState == .closed ? "checkmark.circle.fill" : "laptopcomputer"
                    )
                }
                .buttonStyle(
                    LiquidGlassButtonStyle(
                        tint: AmberVisualTheme.amber,
                        isEmphasized: model.simulatedLidState != .closed,
                        shape: .capsule
                    )
                )
                .disabled(model.simulatedLidState == .closed)
                .accessibilityValue(model.simulatedLidState == .closed ? "当前模拟状态" : "可执行")

                Button {
                    model.simulateLidOpened()
                } label: {
                    Label(
                        "模拟开盖",
                        systemImage: model.simulatedLidState == .opened ? "checkmark.circle.fill" : "laptopcomputer.and.arrow.up"
                    )
                }
                .buttonStyle(
                    LiquidGlassButtonStyle(
                        tint: AmberVisualTheme.seaGlass,
                        isEmphasized: model.simulatedLidState != .opened,
                        shape: .capsule
                    )
                )
                .disabled(model.simulatedLidState == .opened)
                .accessibilityValue(model.simulatedLidState == .opened ? "当前模拟状态" : "可执行")

                Spacer()

                Button {
                    model.resetSimulationState()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(LiquidGlassIconButtonStyle(tint: AmberVisualTheme.mistBlue, size: 36))
                .help("重置模拟状态")
                .accessibilityLabel("重置模拟状态")
            }
        }
        .amberGlassCard(padding: 16, cornerRadius: 22)
    }
}

private struct NowPlayingCard: View {
    @ObservedObject var model: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                CardTitle(title: "当前声音", subtitle: "CoreAudio 实时", systemImage: "waveform")
                Spacer()
                Circle()
                    .fill(model.currentAudioProcesses.isEmpty ? Color.secondary.opacity(0.4) : AmberVisualTheme.seaGlass)
                    .frame(width: 8, height: 8)
            }

            Group {
                if model.currentAudioProcesses.isEmpty {
                    HStack(spacing: 11) {
                        Image(systemName: "speaker.slash")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("当前没有活动音频")
                                .font(.subheadline.weight(.semibold))
                            Text("检测到播放程序后会显示在这里")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(model.currentAudioProcesses.prefix(2), id: \.pid) { process in
                            AudioProcessRow(process: process)
                        }
                        if model.currentAudioProcesses.count > 2 {
                            Text("另有 \(model.currentAudioProcesses.count - 2) 个活动进程")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)

            Spacer(minLength: 0)

            HStack(spacing: 11) {
                Spacer()
                Button { model.sendMediaCommand(.previous) } label: {
                    Image(systemName: "backward.fill")
                }
                .buttonStyle(LiquidGlassIconButtonStyle(tint: AmberVisualTheme.mistBlue))
                .help("上一首")
                .accessibilityLabel("上一首")

                Button { model.sendMediaCommand(.playPause) } label: {
                    Image(systemName: "playpause.fill")
                }
                .buttonStyle(LiquidGlassIconButtonStyle(tint: AmberVisualTheme.amber, isEmphasized: true, size: 48))
                .help("暂停或开始")
                .accessibilityLabel("暂停/开始")

                Button { model.sendMediaCommand(.next) } label: {
                    Image(systemName: "forward.fill")
                }
                .buttonStyle(LiquidGlassIconButtonStyle(tint: AmberVisualTheme.mistBlue))
                .help("下一首")
                .accessibilityLabel("下一首")
                Spacer()
            }

            Text(model.mediaStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .lineLimit(1)
        }
        .amberGlassCard()
    }
}

private struct AudioProcessRow: View {
    let process: AudioProcess

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(AmberVisualTheme.seaGlass.opacity(0.12))
                Image(systemName: "waveform")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(AmberVisualTheme.seaGlass)
            }
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 1) {
                Text(process.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(process.bundleID ?? process.executablePath ?? "PID \(process.pid)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()
            Text("\(process.pid)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

private struct CardTitle: View {
    let title: String
    let subtitle: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(AmberVisualTheme.amber)
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct ActivityTimeline: View {
    @ObservedObject var model: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                CardTitle(title: "活动时间线", subtitle: "永久保存在本机", systemImage: "clock.arrow.circlepath")
                Spacer()
                Text("\(model.events.count) 条")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button {
                    model.clearLog()
                } label: {
                    Label("清空", systemImage: "trash")
                }
                .buttonStyle(
                    LiquidGlassButtonStyle(
                        tint: AmberVisualTheme.danger,
                        isEmphasized: false,
                        shape: .capsule
                    )
                )
            }

            if model.events.isEmpty {
                ContentUnavailableView(
                    "暂无活动记录",
                    systemImage: "checkmark.shield",
                    description: Text("合盖、夜间保护和音频进程事件会显示在这里。")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.events) { event in
                            EventTimelineRow(event: event)
                            if event.id != model.events.last?.id {
                                Divider().opacity(0.22)
                                    .padding(.leading, 46)
                            }
                        }
                    }
                }
                .scrollIndicators(.visible)
            }
        }
        .amberGlassCard(padding: 17, cornerRadius: 26)
    }
}

private struct EventTimelineRow: View {
    let event: LidMuteEvent

    var body: some View {
        let presentation = EventPresentation(kind: event.kind)
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(accent.opacity(0.13))
                Image(systemName: presentation.symbolName)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(accent)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 3) {
                Text(presentation.title)
                    .font(.subheadline.weight(.semibold))
                Text(event.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if let tab = event.chromeTab {
                    Text("\(tab.title) · \(tab.url)")
                        .font(.caption2)
                        .foregroundStyle(AmberVisualTheme.seaGlass)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)
            Text(event.timestamp, style: .time)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }

    private var accent: Color {
        switch event.kind {
        case .error:
            return AmberVisualTheme.danger
        case .chromeTabAudible, .audioProcessDetected, .mediaCommandSent:
            return AmberVisualTheme.seaGlass
        case .restored, .lidOpened, .nightProtectionEnded:
            return AmberVisualTheme.mistBlue
        default:
            return AmberVisualTheme.amber
        }
    }
}
