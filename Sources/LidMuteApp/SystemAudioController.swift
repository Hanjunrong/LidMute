import AppKit
import CoreAudio
import Foundation
import LidMuteCore

final class SystemAudioController: AudioControlling, @unchecked Sendable {
    func resolveBuiltInSpeaker(uid: String?) throws -> AudioDevice? {
        let defaultOutputID = try readDefaultOutputDevice()
        let candidates = try readAudioDeviceIDs().compactMap { deviceID in
            try? makeCandidate(deviceID: deviceID, defaultOutputID: defaultOutputID)
        }
        return AudioDeviceResolver.resolve(candidates, uid: uid)
    }

    func captureState(of device: AudioDevice) throws -> AudioDeviceState {
        try readState(of: device)
    }

    func readState(of device: AudioDevice) throws -> AudioDeviceState {
        let device = try revalidatedBuiltInSpeaker(device)
        let muteAddress = outputAddress(kAudioDevicePropertyMute)
        let volumeAddress = outputAddress(kAudioDevicePropertyVolumeScalar)
        let hasMute = hasProperty(device.id, muteAddress)
        let hasWritableMute = hasMute && isSettable(device.id, muteAddress)
        let muted = hasMute ? (try readUInt32(objectID: device.id, address: muteAddress) != 0) : false
        let volume = hasProperty(device.id, volumeAddress)
            ? try readFloat(objectID: device.id, address: volumeAddress)
            : 1
        return AudioDeviceState(muted: muted, volume: volume, usedVolumeFallback: !hasWritableMute)
    }

    func writeMuted(_ muted: Bool, on device: AudioDevice) throws {
        let device = try revalidatedBuiltInSpeaker(device)
        let muteAddress = outputAddress(kAudioDevicePropertyMute)
        guard hasProperty(device.id, muteAddress), isSettable(device.id, muteAddress) else {
            throw SystemAudioError.noControllableOutput
        }
        try writeUInt32(muted ? 1 : 0, objectID: device.id, address: muteAddress)
    }

    func writeVolume(_ volume: Float, on device: AudioDevice) throws {
        let device = try revalidatedBuiltInSpeaker(device)
        let volumeAddress = outputAddress(kAudioDevicePropertyVolumeScalar)
        guard hasProperty(device.id, volumeAddress), isSettable(device.id, volumeAddress) else {
            throw SystemAudioError.noControllableOutput
        }
        try writeFloat(volume, objectID: device.id, address: volumeAddress)
    }

    func supportsWritableMute(on device: AudioDevice) -> Bool {
        guard let device = try? revalidatedBuiltInSpeaker(device) else { return false }
        let muteAddress = outputAddress(kAudioDevicePropertyMute)
        return hasProperty(device.id, muteAddress) && isSettable(device.id, muteAddress)
    }

    func activeOutputProcesses() throws -> [AudioProcess] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size))
        guard size > 0 else { return [] }

        var processIDs = Array(repeating: AudioObjectID(0), count: Int(size) / MemoryLayout<AudioObjectID>.size)
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &processIDs))

        return processIDs.compactMap { processID in
            guard let pid = try? readInt32(objectID: processID, selector: kAudioProcessPropertyPID),
                  let running = try? readUInt32(objectID: processID, selector: kAudioProcessPropertyIsRunningOutput, scope: kAudioObjectPropertyScopeGlobal),
                  running != 0 else { return nil }
            let application = NSRunningApplication(processIdentifier: pid_t(pid))
            return AudioProcess(
                pid: pid,
                name: application?.localizedName ?? "PID \(pid)",
                bundleID: application?.bundleIdentifier,
                executablePath: application?.executableURL?.path,
                launchDate: application?.launchDate,
                isOutputActive: true
            )
        }
    }

    private func readDefaultOutputDevice() throws -> AudioDeviceID {
        try readUInt32(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyDefaultOutputDevice,
            scope: kAudioObjectPropertyScopeGlobal
        )
    }

    private func readAudioDeviceIDs() throws -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        try check(AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &size))
        guard size % UInt32(MemoryLayout<AudioDeviceID>.size) == 0 else {
            throw SystemAudioError.invalidPropertyData
        }

        var deviceIDs = Array(
            repeating: AudioDeviceID(kAudioObjectUnknown),
            count: Int(size) / MemoryLayout<AudioDeviceID>.size
        )
        guard !deviceIDs.isEmpty else { return [] }
        try check(AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &deviceIDs))
        return deviceIDs
    }

    private func makeCandidate(
        deviceID: AudioDeviceID,
        defaultOutputID: AudioDeviceID
    ) throws -> AudioDeviceCandidate {
        let uid = try readRequiredString(
            objectID: deviceID,
            selector: kAudioDevicePropertyDeviceUID
        )
        let name = try readRequiredString(
            objectID: deviceID,
            selector: kAudioObjectPropertyName
        )
        let transport = try readUInt32(
            objectID: deviceID,
            selector: kAudioDevicePropertyTransportType,
            scope: kAudioObjectPropertyScopeGlobal
        )
        let dataSourceName = try currentOutputDataSourceName(for: deviceID)

        return AudioDeviceCandidate(
            device: AudioDevice(
                id: deviceID,
                uid: uid,
                name: name,
                isBuiltIn: transport == kAudioDeviceTransportTypeBuiltIn
            ),
            isDefault: deviceID == defaultOutputID,
            isInternalTransport: transport == kAudioDeviceTransportTypeBuiltIn,
            dataSourceName: dataSourceName
        )
    }

    private func revalidatedBuiltInSpeaker(_ device: AudioDevice) throws -> AudioDevice {
        guard let resolved = try resolveBuiltInSpeaker(uid: device.uid) else {
            throw SystemAudioError.builtInSpeakerNotValidated
        }
        return resolved
    }

    private func outputAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private func currentOutputDataSourceName(for deviceID: AudioDeviceID) throws -> String {
        let sourceAddress = outputAddress(kAudioDevicePropertyDataSource)
        guard hasProperty(deviceID, sourceAddress) else {
            throw SystemAudioError.missingClassificationProperty
        }
        var sourceID = try readUInt32(objectID: deviceID, address: sourceAddress)
        var sourceName: Unmanaged<CFString>?
        try withUnsafeMutablePointer(to: &sourceID) { sourcePointer in
            try withUnsafeMutablePointer(to: &sourceName) { namePointer in
                var translation = AudioValueTranslation(
                    mInputData: UnsafeMutableRawPointer(sourcePointer),
                    mInputDataSize: UInt32(MemoryLayout<UInt32>.size),
                    mOutputData: UnsafeMutableRawPointer(namePointer),
                    mOutputDataSize: UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
                )
                var size = UInt32(MemoryLayout<AudioValueTranslation>.size)
                var nameAddress = outputAddress(kAudioDevicePropertyDataSourceNameForIDCFString)
                try check(AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &size, &translation))
            }
        }
        guard let sourceName else { throw SystemAudioError.invalidPropertyData }
        let name = sourceName.takeRetainedValue() as String
        guard !name.isEmpty else { throw SystemAudioError.invalidPropertyData }
        return name
    }

    private func hasProperty(_ objectID: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        return AudioObjectHasProperty(objectID, &address)
    }

    private func isSettable(_ objectID: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(objectID, &address, &settable) == noErr && settable.boolValue
    }

    private func readUInt32(objectID: AudioObjectID, selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope) throws -> UInt32 {
        try readUInt32(objectID: objectID, address: .init(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain))
    }

    private func readInt32(objectID: AudioObjectID, selector: AudioObjectPropertySelector) throws -> Int32 {
        var value: Int32 = 0
        var size = UInt32(MemoryLayout<Int32>.size)
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        try check(AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value))
        return value
    }

    private func readUInt32(objectID: AudioObjectID, address: AudioObjectPropertyAddress) throws -> UInt32 {
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = address
        try check(AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value))
        return value
    }

    private func readFloat(objectID: AudioObjectID, address: AudioObjectPropertyAddress) throws -> Float {
        var value: Float = 0
        var size = UInt32(MemoryLayout<Float>.size)
        var address = address
        try check(AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value))
        return value
    }

    private func readString(objectID: AudioObjectID, selector: AudioObjectPropertySelector) throws -> String {
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        try check(AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value))
        guard let value else { return "" }
        return value.takeRetainedValue() as String
    }

    private func readRequiredString(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) throws -> String {
        let value = try readString(objectID: objectID, selector: selector)
        guard !value.isEmpty else { throw SystemAudioError.invalidPropertyData }
        return value
    }

    private func writeUInt32(_ value: UInt32, objectID: AudioObjectID, address: AudioObjectPropertyAddress) throws {
        var value = value
        var address = address
        try check(AudioObjectSetPropertyData(objectID, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value))
    }

    private func writeFloat(_ value: Float, objectID: AudioObjectID, address: AudioObjectPropertyAddress) throws {
        var value = value
        var address = address
        try check(AudioObjectSetPropertyData(objectID, &address, 0, nil, UInt32(MemoryLayout<Float>.size), &value))
    }

    private func check(_ status: OSStatus) throws {
        guard status == noErr else { throw SystemAudioError.coreAudio(status) }
    }
}

enum SystemAudioError: LocalizedError {
    case coreAudio(OSStatus)
    case noControllableOutput
    case builtInSpeakerNotValidated
    case missingClassificationProperty
    case invalidPropertyData

    var errorDescription: String? {
        switch self {
        case let .coreAudio(status): return "CoreAudio 错误：\(status)"
        case .noControllableOutput: return "内建扬声器没有可写的静音或音量控制"
        case .builtInSpeakerNotValidated: return "无法重新验证内建扬声器"
        case .missingClassificationProperty: return "音频设备缺少必需的分类属性"
        case .invalidPropertyData: return "CoreAudio 返回了无效的设备属性"
        }
    }
}
