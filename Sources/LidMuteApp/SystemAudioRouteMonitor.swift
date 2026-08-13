import CoreAudio
import Foundation

@MainActor
final class SystemAudioRouteMonitor {
    private let systemObject = AudioObjectID(kAudioObjectSystemObject)
    private let listenerQueue = DispatchQueue.main
    private let onChange: @MainActor () -> Void
    private var acceptsChanges = false
    private var defaultOutputListenerRegistered = false
    private var devicesListenerRegistered = false
    private var pendingChange: Task<Void, Never>?

    private lazy var defaultOutputListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        Task { @MainActor [weak self] in
            guard self?.acceptsChanges == true else { return }
            self?.scheduleChange()
        }
    }
    private lazy var devicesListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        Task { @MainActor [weak self] in
            guard self?.acceptsChanges == true else { return }
            self?.scheduleChange()
        }
    }

    init(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
    }

    func start() throws {
        guard !acceptsChanges else { return }
        try removeRegisteredListeners()

        var defaultOutputAddress = propertyAddress(kAudioHardwarePropertyDefaultOutputDevice)
        try check(AudioObjectAddPropertyListenerBlock(
            systemObject,
            &defaultOutputAddress,
            listenerQueue,
            defaultOutputListener
        ))
        defaultOutputListenerRegistered = true

        var devicesAddress = propertyAddress(kAudioHardwarePropertyDevices)
        do {
            try check(AudioObjectAddPropertyListenerBlock(
                systemObject,
                &devicesAddress,
                listenerQueue,
                devicesListener
            ))
            devicesListenerRegistered = true
        } catch {
            _ = removeDefaultOutputListener()
            throw error
        }
        acceptsChanges = true
    }

    func stop() {
        acceptsChanges = false
        pendingChange?.cancel()
        pendingChange = nil
        _ = removeDefaultOutputListener()
        _ = removeDevicesListener()
    }

    private func scheduleChange() {
        guard acceptsChanges, pendingChange == nil else { return }
        pendingChange = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, acceptsChanges, !Task.isCancelled else { return }
            pendingChange = nil
            onChange()
        }
    }

    private func removeRegisteredListeners() throws {
        if let status = removeDefaultOutputListener() {
            throw SystemAudioRouteMonitorError.coreAudio(status)
        }
        if let status = removeDevicesListener() {
            throw SystemAudioRouteMonitorError.coreAudio(status)
        }
    }

    private func removeDefaultOutputListener() -> OSStatus? {
        guard defaultOutputListenerRegistered else { return nil }
        var address = propertyAddress(kAudioHardwarePropertyDefaultOutputDevice)
        let status = AudioObjectRemovePropertyListenerBlock(
            systemObject,
            &address,
            listenerQueue,
            defaultOutputListener
        )
        guard status == noErr else { return status }
        defaultOutputListenerRegistered = false
        return nil
    }

    private func removeDevicesListener() -> OSStatus? {
        guard devicesListenerRegistered else { return nil }
        var address = propertyAddress(kAudioHardwarePropertyDevices)
        let status = AudioObjectRemovePropertyListenerBlock(
            systemObject,
            &address,
            listenerQueue,
            devicesListener
        )
        guard status == noErr else { return status }
        devicesListenerRegistered = false
        return nil
    }

    private func propertyAddress(
        _ selector: AudioObjectPropertySelector
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private func check(_ status: OSStatus) throws {
        guard status == noErr else { throw SystemAudioRouteMonitorError.coreAudio(status) }
    }
}

private enum SystemAudioRouteMonitorError: Error {
    case coreAudio(OSStatus)
}
