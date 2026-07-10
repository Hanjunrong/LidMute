import Foundation
import IOKit
import IOKit.pwr_mgt

@MainActor
final class SystemLidMonitor {
    private var timer: Timer?
    private var lastState: Bool?
    private let onChange: (Bool) -> Void

    init(onChange: @escaping (Bool) -> Void) {
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
        guard let current = readClamshellState() else { return }
        if current != lastState {
            lastState = current
            onChange(current)
        }
    }

    private func readClamshellState() -> Bool? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }
        let key = "AppleClamshellState" as CFString
        guard let value = IORegistryEntryCreateCFProperty(service, key, kCFAllocatorDefault, 0) else { return nil }
        return (value.takeRetainedValue() as? Bool)
    }
}
