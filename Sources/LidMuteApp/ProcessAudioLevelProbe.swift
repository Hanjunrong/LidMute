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

    func hasAudibleOutput(pid: pid_t, duration: TimeInterval = 0.12) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let tap = ProcessAudioTap()
        let peak = PeakBox()
        do {
            try tap.start(pid: pid) { bufferPeak in
                peak.value = max(peak.value, bufferPeak)
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

    // Measure every channel independently: mixing channels can cancel audible
    // out-of-phase samples, and non-interleaved audio spans multiple buffers.
    static func peak(in inputData: UnsafePointer<AudioBufferList>) -> Float {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        var peak: Float = 0
        for buffer in buffers {
            guard let data = buffer.mData else { continue }
            let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            let samples = data.assumingMemoryBound(to: Float.self)
            for index in 0..<count {
                let magnitude = abs(samples[index])
                if magnitude.isFinite { peak = max(peak, magnitude) }
            }
        }
        return peak
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

    func start(pid: pid_t, handler: @escaping @Sendable (Float) -> Void) throws {
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

        var newIOProcID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&newIOProcID, aggregateID, ioQueue) {
            _, inputData, _, _, _ in
            handler(ProcessAudioLevelProbe.peak(in: inputData))
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
