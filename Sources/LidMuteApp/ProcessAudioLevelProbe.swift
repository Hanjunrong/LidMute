import AudioToolbox
import CoreAudio
import Foundation

/// Measures whether one CoreAudio process produced non-silent samples recently.
/// The process list's IsRunningOutput bit is only a routing/lifecycle signal and
/// stays true for paused players, so the card uses this probe before presenting a
/// process as current audio.
final class ProcessAudioLevelProbe: @unchecked Sendable {
    private final class PeakBox: @unchecked Sendable {
        var value: Float = 0
    }

    private let lock = NSLock()
    private var active = false

    func hasAudibleOutput(pid: pid_t, duration: TimeInterval = 0.12) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !active else { return true }
        active = true
        defer { active = false }

        let tap = ProcessAudioTap()
        let peak = PeakBox()
        do {
            try tap.start(pid: pid) { samples in
                for sample in samples {
                    let magnitude = abs(sample)
                    if magnitude > peak.value { peak.value = magnitude }
                }
            }
            Thread.sleep(forTimeInterval: duration)
            tap.stop()
            return ProcessAudioLevelProbe.isAudible(peak: peak.value)
        } catch {
            tap.stop()
            // A failed tap is not evidence of audio. In particular, falling back
            // to IsRunningOutput here would reintroduce the paused-player bug.
            return false
        }
    }

    static func isAudible(peak: Float, threshold: Float = 0.0005) -> Bool {
        peak.isFinite && peak > threshold
    }
}

enum ProcessAudioTapConfiguration {
    static func aggregateDescription(tapUUID: UUID, outputUID: String, name: String) -> [String: Any] {
        [
            kAudioAggregateDeviceNameKey: name,
            kAudioAggregateDeviceUIDKey: "local.lidmute.process-tap.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: tapUUID.uuidString
                ]
            ]
        ]
    }
}

private final class ProcessAudioTap {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private let ioQueue = DispatchQueue(label: "local.lidmute.process-audio-tap", qos: .userInteractive)
    private var scratch: UnsafeMutableBufferPointer<Float>?

    func start(pid: pid_t, handler: @escaping @Sendable (UnsafeBufferPointer<Float>) -> Void) throws {
        let processObjectID = try translatePID(pid)
        let description = CATapDescription(stereoMixdownOfProcesses: [processObjectID])
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .unmuted
        description.name = "LidMute Process Activity Tap"

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(description, &newTapID), "create process tap")
        tapID = newTapID

        let outputUID = try defaultOutputDeviceUID()
        let composition = ProcessAudioTapConfiguration.aggregateDescription(
            tapUUID: description.uuid,
            outputUID: outputUID,
            name: "LidMute Process Activity Aggregate"
        )
        var newAggregateID = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateAggregateDevice(composition as CFDictionary, &newAggregateID), "create process tap aggregate")
        aggregateID = newAggregateID

        var bufferFrames: UInt32 = 512
        var bufferAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        _ = AudioObjectSetPropertyData(
            aggregateID,
            &bufferAddress,
            0,
            nil,
            UInt32(MemoryLayout<UInt32>.size),
            &bufferFrames
        )

        let scratch = UnsafeMutableBufferPointer<Float>.allocate(capacity: 4096)
        self.scratch = scratch
        var newIOProcID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&newIOProcID, aggregateID, ioQueue) {
            [weak self] _, inputData, _, _, _ in
            guard let self, let scratch = self.scratch else { return }
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
            for buffer in buffers {
                guard let data = buffer.mData else { continue }
                let sampleCount = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                let samples = data.bindMemory(to: Float.self, capacity: sampleCount)
                let channels = max(Int(buffer.mNumberChannels), 1)
                let frames = min(sampleCount / channels, scratch.count)
                if channels == 1 {
                    for index in 0..<frames { scratch[index] = samples[index] }
                } else {
                    let scale = 1 / Float(channels)
                    for frame in 0..<frames {
                        var sum: Float = 0
                        for channel in 0..<channels { sum += samples[frame * channels + channel] }
                        scratch[frame] = sum * scale
                    }
                }
                handler(UnsafeBufferPointer(rebasing: scratch[0..<frames]))
                break
            }
        }
        try check(status, "create process tap IO")
        guard let newIOProcID else { throw TapError.invalidIOProc }
        ioProcID = newIOProcID
        try check(AudioDeviceStart(aggregateID, newIOProcID), "start process tap IO")
    }

    func stop() {
        if let ioProcID, aggregateID != kAudioObjectUnknown {
            _ = AudioDeviceStop(aggregateID, ioProcID)
            _ = AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil
        if aggregateID != kAudioObjectUnknown {
            _ = AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            _ = AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
        scratch?.deallocate()
        scratch = nil
    }

    private enum TapError: Error { case invalidIOProc }

    private func translatePID(_ pid: pid_t) throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pidValue = pid
        var objectID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &pidValue) { pointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<pid_t>.size),
                pointer,
                &size,
                &objectID
            )
        }
        try check(status, "translate process PID")
        guard objectID != kAudioObjectUnknown else { throw TapError.invalidIOProc }
        return objectID
    }

    private func defaultOutputDeviceUID() throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        ), "read default output device")

        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: Unmanaged<CFString>?
        var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try check(AudioObjectGetPropertyData(
            deviceID, &uidAddress, 0, nil, &uidSize, &uid
        ), "read default output UID")
        guard let uid else { throw TapError.invalidIOProc }
        let value = uid.takeRetainedValue() as String
        guard !value.isEmpty else { throw TapError.invalidIOProc }
        return value
    }

    private func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else { throw NSError(domain: "LidMute.ProcessAudioTap", code: Int(status), userInfo: [NSLocalizedDescriptionKey: operation]) }
    }

    deinit { stop() }
}
