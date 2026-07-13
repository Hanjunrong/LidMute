import Foundation

public struct AudioSourcePresentation: Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let subtitle: String
    public let symbolName: String
    public let process: AudioProcess?
    public let chromeTab: ChromeTabEvidence?

    public init(process: AudioProcess?, chromeTab: ChromeTabEvidence?) {
        self.process = process
        self.chromeTab = chromeTab

        if let chromeTab {
            id = "chrome-\(chromeTab.sessionID)-\(chromeTab.windowID)-\(chromeTab.tabID)"
            title = Self.nonempty(chromeTab.title) ?? process.map(Self.readableName) ?? "Google Chrome"
            subtitle = [process.map(Self.readableName) ?? "Google Chrome", Self.nonempty(chromeTab.url)]
                .compactMap { $0 }
                .joined(separator: " · ")
            symbolName = "globe"
        } else if let process {
            id = "process-\(process.pid)"
            title = Self.readableName(for: process)
            subtitle = Self.nonempty(process.bundleID) ?? Self.nonempty(process.executablePath) ?? ""
            symbolName = "app.fill"
        } else {
            id = "unknown"
            title = "未知音频来源"
            subtitle = ""
            symbolName = "waveform"
        }
    }

    public init?(event: LidMuteEvent) {
        guard event.process != nil || event.chromeTab != nil else { return nil }
        self.init(process: event.process, chromeTab: event.chromeTab)
    }

    public static func current(
        processes: [AudioProcess],
        chromeTab: ChromeTabEvidence?
    ) -> [Self] {
        var attachedChromeTab = false
        return processes.filter(\.isOutputActive).map { process in
            let evidence: ChromeTabEvidence?
            if !attachedChromeTab, isChrome(process), let chromeTab {
                evidence = chromeTab
                attachedChromeTab = true
            } else {
                evidence = nil
            }
            return Self(process: process, chromeTab: evidence)
        }
    }

    public static func isChrome(_ process: AudioProcess) -> Bool {
        process.bundleID?.localizedCaseInsensitiveContains("chrome") == true ||
            process.name.localizedCaseInsensitiveContains("chrome")
    }

    private static func readableName(for process: AudioProcess) -> String {
        let fallback = "PID \(process.pid)"
        guard let name = nonempty(process.name), name != fallback else { return fallback }
        return name
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
