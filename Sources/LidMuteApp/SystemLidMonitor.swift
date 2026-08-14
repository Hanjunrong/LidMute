import Foundation
import IOKit
import IOKit.pwr_mgt

enum LidMonitorResult: Equatable {
    case state(Bool)
    case unavailable
    case readFailed
}

@MainActor
final class SystemLidMonitor {
    private var timer: Timer?
    private var lastResult: LidMonitorResult?
    private let onChange: (LidMonitorResult) -> Void

    init(onChange: @escaping (LidMonitorResult) -> Void) {
        self.onChange = onChange
    }

    func start() {
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.poll() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        let result = readClamshellState()
        if result != lastResult {
            lastResult = result
            onChange(result)
        }
    }

    private func readClamshellState() -> LidMonitorResult {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != IO_OBJECT_NULL else { return .unavailable }
        defer { IOObjectRelease(service) }
        let key = "AppleClamshellState" as CFString
        guard let value = IORegistryEntryCreateCFProperty(service, key, kCFAllocatorDefault, 0),
              let state = value.takeRetainedValue() as? Bool else { return .readFailed }
        return .state(state)
    }
}
