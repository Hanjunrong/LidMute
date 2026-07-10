import AppKit
import CoreAudio
import Foundation
import LidMuteCore

final class SystemAudioController: AudioControlling, @unchecked Sendable {
    func builtInSpeaker() throws -> AudioDevice? {
        let deviceID = try readDefaultOutputDevice()
        guard deviceID != kAudioObjectUnknown else { return nil }

        let transport = try readUInt32(
            objectID: deviceID,
            selector: kAudioDevicePropertyTransportType,
            scope: kAudioObjectPropertyScopeGlobal
        )
        guard transport == kAudioDeviceTransportTypeBuiltIn else { return nil }
        let name = try readString(objectID: deviceID, selector: kAudioObjectPropertyName)
        guard isClearlyInternalSpeaker(named: name) else { return nil }

        return AudioDevice(
            id: deviceID,
            uid: try readString(objectID: deviceID, selector: kAudioDevicePropertyDeviceUID),
            name: name,
            isBuiltIn: true
        )
    }

    func captureState(of device: AudioDevice) throws -> AudioDeviceState {
        let muteAddress = outputAddress(kAudioDevicePropertyMute)
        let volumeAddress = outputAddress(kAudioDevicePropertyVolumeScalar)
        let hasMute = hasProperty(device.id, muteAddress)
        let muted = hasMute ? (try readUInt32(objectID: device.id, address: muteAddress) != 0) : false
        let volume = hasProperty(device.id, volumeAddress)
            ? try readFloat(objectID: device.id, address: volumeAddress)
            : 1
        return AudioDeviceState(muted: muted, volume: volume, usedVolumeFallback: !hasMute)
    }

    func enforceSilence(on device: AudioDevice) throws {
        let muteAddress = outputAddress(kAudioDevicePropertyMute)
        if hasProperty(device.id, muteAddress), isSettable(device.id, muteAddress) {
            try writeUInt32(1, objectID: device.id, address: muteAddress)
            return
        }

        let volumeAddress = outputAddress(kAudioDevicePropertyVolumeScalar)
        guard hasProperty(device.id, volumeAddress), isSettable(device.id, volumeAddress) else {
            throw SystemAudioError.noControllableOutput
        }
        try writeFloat(0, objectID: device.id, address: volumeAddress)
    }

    func restore(_ state: AudioDeviceState, on device: AudioDevice) throws {
        let volumeAddress = outputAddress(kAudioDevicePropertyVolumeScalar)
        if hasProperty(device.id, volumeAddress), isSettable(device.id, volumeAddress) {
            try writeFloat(state.volume, objectID: device.id, address: volumeAddress)
        }

        let muteAddress = outputAddress(kAudioDevicePropertyMute)
        if hasProperty(device.id, muteAddress), isSettable(device.id, muteAddress) {
            try writeUInt32(state.muted ? 1 : 0, objectID: device.id, address: muteAddress)
        }
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

    private func outputAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private func isClearlyInternalSpeaker(named name: String) -> Bool {
        let normalized = name.lowercased()
        return normalized.contains("speaker") || normalized.contains("扬声器") || normalized.contains("喇叭")
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

    var errorDescription: String? {
        switch self {
        case let .coreAudio(status): return "CoreAudio 错误：\(status)"
        case .noControllableOutput: return "内建扬声器没有可写的静音或音量控制"
        }
    }
}
