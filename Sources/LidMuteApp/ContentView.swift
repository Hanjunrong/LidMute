import SwiftUI
import LidMuteCore

struct ContentView: View {
    @ObservedObject var model: AppViewModel
    private let cardSpacing = CGFloat(VisualLayoutMetrics.cardSpacing)
    private let appPadding = CGFloat(VisualLayoutMetrics.appPadding)

    var body: some View {
        ZStack {
            AmberAtmosphere()
                .ignoresSafeArea()

            GeometryReader { proxy in
                let availableContentHeight = max(0, Double(proxy.size.height - appPadding * 2))
                let timelineViewportHeight = CGFloat(
                    VisualLayoutMetrics.timelineViewportHeight(
                        forAvailableContentHeight: availableContentHeight
                    )
                )

                VStack(spacing: cardSpacing) {
                    HeaderBar(model: model)
                        .frame(height: CGFloat(VisualLayoutMetrics.headerHeight))

                    GuardHero(model: model)
                        .frame(height: CGFloat(VisualLayoutMetrics.guardCardHeight))

                    HStack(alignment: .top, spacing: cardSpacing) {
                        VStack(spacing: cardSpacing) {
                            AutomationCard(model: model)
                                .frame(maxWidth: .infinity)
                                .frame(height: CGFloat(VisualLayoutMetrics.automationCardHeight))
                            SimulationCard(model: model)
                                .frame(maxWidth: .infinity)
                                .frame(height: CGFloat(VisualLayoutMetrics.simulationCardHeight))
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: CGFloat(VisualLayoutMetrics.middleDeckHeight))

                        NowPlayingCard(model: model)
                            .frame(maxWidth: .infinity)
                            .frame(height: CGFloat(VisualLayoutMetrics.middleDeckHeight))
                    }
                    .frame(height: CGFloat(VisualLayoutMetrics.middleDeckHeight))

                    ActivityTimeline(model: model, viewportHeight: timelineViewportHeight)
                }
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(appPadding)
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
            }
        }
        .frame(minWidth: 900, minHeight: 680)
    }
}

private struct HeaderBar: View {
    @ObservedObject var model: AppViewModel
    @State private var showChromeGuide = false
    @Environment(\.colorScheme) private var colorScheme

    private var palette: AmberThemePalette {
        AmberVisualTheme.palette(for: colorScheme)
    }

    var body: some View {
        HStack(spacing: 13) {
            AuroraSymbolTile(
                systemImage: "shield.lefthalf.filled",
                tint: AmberVisualTheme.amber,
                secondaryTint: AmberVisualTheme.seaGlass,
                size: 46,
                cornerRadius: 13
            )

            VStack(alignment: .leading, spacing: 1) {
                Text("LidMute")
                    .font(ControlCenterTypography.brand)
                    .tracking(-0.35)
                Text("合盖监控系统外放守卫")
                    .font(ControlCenterTypography.caption)
                    .foregroundStyle(palette.secondaryText)
            }

            Spacer()

            Button {
                showChromeGuide.toggle()
            } label: {
                HStack(spacing: 8) {
                    Circle()
                        .fill(chromeDotColor)
                        .frame(width: 7, height: 7)
                    Text(model.chromeBridgeStatus)
                        .font(ControlCenterTypography.caption)
                        .foregroundStyle(palette.secondaryText)
                        .lineLimit(1)
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(palette.controlFill, in: Capsule())
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showChromeGuide) {
                ChromeGuideView(model: model)
            }
        }
        .padding(.horizontal, 4)
    }

    private var chromeDotColor: Color {
        switch model.chromeConnectionState {
        case .receivedEvent, .connected:
            return AmberVisualTheme.seaGlass
        case .waitingForExtension:
            return AmberVisualTheme.amber.opacity(0.55)
        case .notRegistered, .unknown:
            return Color.secondary.opacity(0.45)
        }
    }
}

private struct GuardHero: View {
    @ObservedObject var model: AppViewModel
    @Environment(\.colorScheme) private var colorScheme

    private var palette: AmberThemePalette {
        AmberVisualTheme.palette(for: colorScheme)
    }

    var body: some View {
        HStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 9) {
                Label(model.isEnabled ? "守卫已开启" : "守卫未开启", systemImage: model.isEnabled ? "shield.fill" : "shield.slash")
                    .font(ControlCenterTypography.heroEyebrow)
                    .foregroundStyle(model.isEnabled ? AmberVisualTheme.amber : palette.secondaryText)

                Text(heroTitle)
                    .font(ControlCenterTypography.heroTitle)
                    .tracking(-0.65)

                Text(heroSubtitle)
                    .font(ControlCenterTypography.body)
                    .foregroundStyle(palette.secondaryText)

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
        .frame(maxHeight: .infinity)
        .padding(10)
        .amberGlassCard(role: .hero, padding: 0, cornerRadius: 14)
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
            .font(ControlCenterTypography.compactCaption)
            .foregroundStyle(tint)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(tint.opacity(0.16), in: Capsule())
            .overlay(Capsule().stroke(tint.opacity(0.35), lineWidth: 0.8))
    }
}

private struct AutomationCard: View {
    @ObservedObject var model: AppViewModel
    @Environment(\.colorScheme) private var colorScheme

    private var palette: AmberThemePalette {
        AmberVisualTheme.palette(for: colorScheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                CardTitle(
                    title: "自动保护",
                    subtitle: "合盖与夜间策略",
                    systemImage: "sparkles",
                    tint: AmberVisualTheme.amber
                )
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
                    .padding(5)
                    .background(
                        Capsule()
                            .fill(AmberVisualTheme.amber.opacity(0.12))
                    )
                    .overlay(
                        Capsule()
                            .stroke(AmberVisualTheme.amber.opacity(0.25), lineWidth: 0.8)
                    )
            }

            HStack(spacing: 9) {
                TextField("00:00", text: $model.nightStartText)
                    .textFieldStyle(.plain)
                    .font(ControlCenterTypography.numeric)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 8)
                    .background(palette.controlFill, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(palette.border))
                    .onChange(of: model.nightStartText) { _, _ in model.nightScheduleTextChanged() }
                    .disabled(!model.isEnabled)

                Image(systemName: "arrow.right")
                    .font(ControlCenterTypography.caption)
                    .foregroundStyle(palette.secondaryText)

                TextField("08:00", text: $model.nightEndText)
                    .textFieldStyle(.plain)
                    .font(ControlCenterTypography.numeric)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 8)
                    .background(palette.controlFill, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(palette.border))
                    .onChange(of: model.nightEndText) { _, _ in model.nightScheduleTextChanged() }
                    .disabled(!model.isEnabled)
            }

            Text("\(model.nightScheduleStatus) · \(model.isDisplaySleeping ? "当前息屏" : "当前亮屏")")
                .font(ControlCenterTypography.caption)
                .foregroundStyle(palette.secondaryText)
                .lineLimit(1)

        }
        .frame(maxHeight: .infinity)
        .opacity(model.isEnabled ? 1 : 0.62)
        .padding(10)
        .amberGlassCard(role: .standard, padding: 0, cornerRadius: 14)
    }
}

private struct SimulationCard: View {
    @ObservedObject var model: AppViewModel

    var body: some View {
        HStack(spacing: 16) {
            CardTitle(
                title: "模拟测试",
                subtitle: "独立验证合盖状态",
                systemImage: "testtube.2",
                tint: AmberVisualTheme.mistBlue
            )

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
        .frame(maxHeight: .infinity)
        .padding(10)
        .amberGlassCard(role: .standard, padding: 0, cornerRadius: 14)
    }
}

private struct NowPlayingCard: View {
    @ObservedObject var model: AppViewModel
    @Environment(\.colorScheme) private var colorScheme

    private var palette: AmberThemePalette {
        AmberVisualTheme.palette(for: colorScheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                CardTitle(
                    title: "当前声音",
                    subtitle: "CoreAudio 实时",
                    systemImage: "waveform",
                    tint: AmberVisualTheme.seaGlass
                )
                Spacer()
                Circle()
                    .fill(model.currentAudioProcesses.isEmpty ? Color.secondary.opacity(0.4) : AmberVisualTheme.seaGlass)
                    .frame(width: 8, height: 8)
            }

            if model.currentAudioProcesses.isEmpty {
                Label("当前没有活动音频", systemImage: "speaker.slash")
                    .font(ControlCenterTypography.body)
                    .foregroundStyle(palette.secondaryText)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(model.currentAudioProcesses, id: \.pid) { process in
                            AudioProcessRow(process: process)
                        }
                    }
                }
                // The card's 190pt outer frame includes its 8pt glass-card padding.
                // Keep the two-row viewport within the remaining content height.
                .frame(height: 70)
                .scrollIndicators(.visible)
            }

            HStack(spacing: 8) {
                Spacer()
                Button { model.sendMediaCommand(.previous) } label: {
                    Image(systemName: "backward.fill")
                }
                .buttonStyle(LiquidGlassIconButtonStyle(tint: AmberVisualTheme.mistBlue, size: 32))
                .help("上一首")
                .accessibilityLabel("上一首")

                Button { model.sendMediaCommand(.playPause) } label: {
                    Image(systemName: "playpause.fill")
                }
                .buttonStyle(LiquidGlassIconButtonStyle(tint: AmberVisualTheme.amber, isEmphasized: true, size: 36))
                .help("暂停或开始")
                .accessibilityLabel("暂停/开始")

                Button { model.sendMediaCommand(.next) } label: {
                    Image(systemName: "forward.fill")
                }
                .buttonStyle(LiquidGlassIconButtonStyle(tint: AmberVisualTheme.mistBlue, size: 32))
                .help("下一首")
                .accessibilityLabel("下一首")
                Spacer()
            }

            Text(model.mediaStatus)
                .font(ControlCenterTypography.compactCaption)
                .foregroundStyle(palette.tertiaryText)
                .frame(maxWidth: .infinity, alignment: .center)
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity)
        .padding(8)
        .amberGlassCard(role: .media, padding: 0, cornerRadius: 14)
    }
}

private struct AudioProcessRow: View {
    let process: AudioProcess
    @Environment(\.colorScheme) private var colorScheme

    private var palette: AmberThemePalette {
        AmberVisualTheme.palette(for: colorScheme)
    }

    var body: some View {
        HStack(spacing: 10) {
            AuroraSymbolTile(
                systemImage: "waveform",
                tint: AmberVisualTheme.seaGlass,
                secondaryTint: AmberVisualTheme.mistBlue,
                size: 32,
                cornerRadius: 9
            )

            VStack(alignment: .leading, spacing: 1) {
                Text(process.name)
                    .font(ControlCenterTypography.cardTitle)
                    .lineLimit(1)
                Text(process.bundleID ?? process.executablePath ?? "PID \(process.pid)")
                    .font(ControlCenterTypography.caption)
                    .foregroundStyle(palette.secondaryText)
                    .lineLimit(1)
            }

            Spacer()
            Text("\(process.pid)")
                .font(ControlCenterTypography.numericCaption)
                .foregroundStyle(palette.tertiaryText)
        }
    }
}

private struct CardTitle: View {
    let title: String
    let subtitle: String
    let systemImage: String
    var tint: Color = AmberVisualTheme.amber
    @Environment(\.colorScheme) private var colorScheme

    private var palette: AmberThemePalette {
        AmberVisualTheme.palette(for: colorScheme)
    }

    var body: some View {
        HStack(spacing: 9) {
            AuroraSymbolTile(
                systemImage: systemImage,
                tint: tint,
                secondaryTint: AmberVisualTheme.seaGlass,
                size: 32,
                cornerRadius: 9
            )
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(ControlCenterTypography.cardTitle)
                    .tracking(-0.15)
                Text(subtitle)
                    .font(ControlCenterTypography.caption)
                    .foregroundStyle(palette.secondaryText)
            }
        }
    }
}

private struct ActivityTimeline: View {
    @ObservedObject var model: AppViewModel
    let viewportHeight: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    private var palette: AmberThemePalette {
        AmberVisualTheme.palette(for: colorScheme)
    }

    private let rowHeight = CGFloat(VisualLayoutMetrics.timelineRowHeight)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                CardTitle(
                    title: "活动时间线",
                    subtitle: "永久保存在本机",
                    systemImage: "clock.arrow.circlepath",
                    tint: AmberVisualTheme.mistBlue
                )
                Spacer()
                Text("\(model.events.count) 条")
                    .font(ControlCenterTypography.numericCaption)
                    .foregroundStyle(palette.secondaryText)
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

            Group {
                if model.events.isEmpty {
                    ContentUnavailableView(
                        "暂无活动记录",
                        systemImage: "checkmark.shield",
                        description: Text("合盖、夜间保护和音频进程事件会显示在这里。")
                    )
                    .frame(maxWidth: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(model.events.enumerated()), id: \.element.id) { index, event in
                                EventTimelineRow(
                                    event: event,
                                    rowHeight: rowHeight,
                                    showsDivider: index < model.events.count - 1
                                )
                            }
                        }
                    }
                    .scrollIndicators(.visible)
                }
            }
            .frame(height: max(CGFloat(VisualLayoutMetrics.timelineDefaultViewportHeight), viewportHeight))
        }
        .padding(10)
        .amberGlassCard(role: .timeline, padding: 0, cornerRadius: 14)
    }
}

private struct EventTimelineRow: View {
    let event: LidMuteEvent
    let rowHeight: CGFloat
    let showsDivider: Bool
    @Environment(\.colorScheme) private var colorScheme

    private var palette: AmberThemePalette {
        AmberVisualTheme.palette(for: colorScheme)
    }

    var body: some View {
        let presentation = EventPresentation(kind: event.kind)
        HStack(alignment: .top, spacing: 12) {
            AuroraSymbolTile(
                systemImage: presentation.symbolName,
                tint: accent,
                secondaryTint: AmberVisualTheme.mistBlue,
                size: 34,
                cornerRadius: 17
            )

            VStack(alignment: .leading, spacing: 3) {
                Text(presentation.title)
                    .font(ControlCenterTypography.cardTitle)
                Text(event.detail)
                    .font(ControlCenterTypography.caption)
                    .foregroundStyle(palette.secondaryText)
                    .lineLimit(1)
                if let tab = event.chromeTab {
                    Text("\(tab.title) · \(tab.url)")
                        .font(ControlCenterTypography.compactCaption)
                        .foregroundStyle(AmberVisualTheme.seaGlass)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)
            Text(event.timestamp, style: .time)
                .font(ControlCenterTypography.numericCaption)
                .foregroundStyle(palette.tertiaryText)
        }
        .padding(.vertical, 8)
        .frame(height: rowHeight, alignment: .top)
        .overlay(alignment: .bottom) {
            if showsDivider {
                Rectangle()
                    .fill(palette.border)
                    .frame(height: 1)
                    .padding(.leading, 46)
            }
        }
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

private struct ChromeGuideView: View {
    @ObservedObject var model: AppViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    private var palette: AmberThemePalette {
        AmberVisualTheme.palette(for: colorScheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            Label("Chrome 扩展连接指南", systemImage: "antenna.radiowaves.left.and.right")
                .font(ControlCenterTypography.cardTitle)
                .foregroundStyle(AmberVisualTheme.amber)

            Divider().opacity(0.3)

            // Connection status
            HStack(spacing: 6) {
                Circle()
                    .fill(statusDotColor)
                    .frame(width: 8, height: 8)
                Text(model.chromeBridgeStatus)
                    .font(ControlCenterTypography.body)
                Spacer()
                if model.chromeConnectionState == .connected || model.chromeConnectionState == .receivedEvent {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(AmberVisualTheme.seaGlass)
                }
            }

            // Registration area
            if model.chromeConnectionState != .connected && model.chromeConnectionState != .receivedEvent {
                VStack(alignment: .leading, spacing: 10) {
                    Text("扩展 ID")
                        .font(ControlCenterTypography.caption)
                        .foregroundStyle(palette.secondaryText)

                    HStack(spacing: 8) {
                        TextField("粘贴 chrome://extensions 中显示的 ID", text: $model.chromeExtensionId)
                            .textFieldStyle(.plain)
                            .font(ControlCenterTypography.codeCaption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(palette.controlFill, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(palette.border))

                        Button {
                            model.registerChromeHost(extensionId: model.chromeExtensionId)
                        } label: {
                            Label("注册", systemImage: "key.fill")
                                .font(ControlCenterTypography.button)
                        }
                        .buttonStyle(
                            LiquidGlassButtonStyle(tint: AmberVisualTheme.seaGlass, isEmphasized: false, shape: .capsule)
                        )
                        .fixedSize()
                    }

                    if !model.chromeRegistrationStatus.isEmpty {
                        Label(model.chromeRegistrationStatus, systemImage: model.chromeRegistrationStatus.contains("失败") ? "exclamationmark.triangle" : "info.circle")
                            .font(ControlCenterTypography.caption)
                            .foregroundStyle(model.chromeRegistrationStatus.contains("失败") ? AmberVisualTheme.danger : palette.secondaryText)
                    }
                }
                .padding(10)
                .background(palette.surfaceTertiary, in: RoundedRectangle(cornerRadius: 10))

                Divider().opacity(0.3)
            }

            // Step-by-step guide
            VStack(alignment: .leading, spacing: 12) {
                GuideStep(number: "1", title: "加载 Chrome 扩展", detail: [
                    "打开 chrome://extensions",
                    "开启右上角「开发者模式」",
                    "点击「加载已解压的扩展程序」",
                    "选择以下目录：",
                ])
                Text(model.chromeExtensionPath)
                    .font(ControlCenterTypography.codeCaption)
                    .foregroundStyle(AmberVisualTheme.seaGlass)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.leading, 28)

                GuideStep(number: "2", title: "注册通信主机", detail: [
                    "复制上一步出现的扩展 ID，粘贴到上方输入框",
                    "点击「注册」按钮自动完成配置",
                ])

                GuideStep(number: "3", title: "验证连接", detail: [
                    "刷新 Chrome 扩展页面（刷新按钮）",
                    "回到 LidMute，状态变为「Chrome 已连接」",
                ])
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private var statusDotColor: Color {
        switch model.chromeConnectionState {
        case .receivedEvent, .connected:
            return AmberVisualTheme.seaGlass
        case .waitingForExtension:
            return AmberVisualTheme.amber.opacity(0.55)
        case .notRegistered, .unknown:
            return Color.secondary.opacity(0.45)
        }
    }
}

private struct GuideStep: View {
    let number: String
    let title: String
    let detail: [String]
    @Environment(\.colorScheme) private var colorScheme

    private var palette: AmberThemePalette {
        AmberVisualTheme.palette(for: colorScheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(AmberVisualTheme.amber.opacity(0.15))
                    Text(number)
                        .font(ControlCenterTypography.compactCaption)
                        .foregroundStyle(AmberVisualTheme.amber)
                }
                .frame(width: 22, height: 22)

                Text(title)
                    .font(ControlCenterTypography.cardTitle)
            }

            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(detail.enumerated()), id: \.offset) { _, line in
                    Text("• \(line)")
                        .font(ControlCenterTypography.caption)
                        .foregroundStyle(palette.secondaryText)
                }
            }
            .padding(.leading, 30)
        }
    }
}
