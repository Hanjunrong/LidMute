import CoreAudio
import Foundation

struct AudioRouteChangeGate: Sendable {
    private(set) var lastDefaultOutputID: AudioDeviceID?
    private var pendingDeviceListChange = false

    init(lastDefaultOutputID: AudioDeviceID? = nil) {
        self.lastDefaultOutputID = lastDefaultOutputID
    }

    mutating func recordDeviceListChange() {
        pendingDeviceListChange = true
    }

    mutating func shouldPublish(
        currentDefaultOutputID: AudioDeviceID?,
        reportDeviceListChanges: Bool = false
    ) -> Bool {
        let deviceListChanged = pendingDeviceListChange
        pendingDeviceListChange = false
        if reportDeviceListChanges, deviceListChanged {
            lastDefaultOutputID = currentDefaultOutputID
            return true
        }
        guard let currentDefaultOutputID,
              currentDefaultOutputID != lastDefaultOutputID else { return false }
        lastDefaultOutputID = currentDefaultOutputID
        return true
    }
}

@MainActor
final class SystemAudioRouteMonitor {
    private let systemObject = AudioObjectID(kAudioObjectSystemObject)
    private let listenerQueue = DispatchQueue.main
    private let onChange: @MainActor () -> Void
    private let readDefaultOutput: @MainActor () -> AudioDeviceID?
    private var reportsDeviceListChanges = false
    private var acceptsChanges = false
    private var defaultOutputListenerRegistered = false
    private var devicesListenerRegistered = false
    private var pendingChange: Task<Void, Never>?
    private var routeChangeGate = AudioRouteChangeGate()

    private lazy var defaultOutputListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        Task { @MainActor [weak self] in
            guard self?.acceptsChanges == true else { return }
            self?.scheduleChange(deviceListChanged: false)
        }
    }
    private lazy var devicesListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        Task { @MainActor [weak self] in
            guard self?.acceptsChanges == true else { return }
            self?.scheduleChange(deviceListChanged: true)
        }
    }

    init(
        onChange: @escaping @MainActor () -> Void,
        readDefaultOutput: @escaping @MainActor () -> AudioDeviceID? = {
            SystemAudioRouteMonitor.readCurrentDefaultOutput()
        }
    ) {
        self.onChange = onChange
        self.readDefaultOutput = readDefaultOutput
    }

    func start(reportDeviceListChanges: Bool = false) throws {
        reportsDeviceListChanges = reportDeviceListChanges
        guard !acceptsChanges else { return }
        try removeRegisteredListeners()
        routeChangeGate = AudioRouteChangeGate()
        _ = routeChangeGate.shouldPublish(currentDefaultOutputID: readDefaultOutput())

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
        routeChangeGate = AudioRouteChangeGate()
        _ = removeDefaultOutputListener()
        _ = removeDevicesListener()
    }

    private func scheduleChange(deviceListChanged: Bool) {
        guard acceptsChanges else { return }
        if deviceListChanged {
            routeChangeGate.recordDeviceListChange()
        }
        guard pendingChange == nil else { return }
        pendingChange = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, acceptsChanges, !Task.isCancelled else { return }
            pendingChange = nil
            guard routeChangeGate.shouldPublish(
                currentDefaultOutputID: readDefaultOutput(),
                reportDeviceListChanges: reportsDeviceListChanges
            ) else { return }
            onChange()
        }
    }

    private static func readCurrentDefaultOutput() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
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
