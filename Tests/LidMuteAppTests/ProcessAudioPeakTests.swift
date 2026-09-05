import CoreAudio
import XCTest
@testable import LidMuteApp

final class ProcessAudioPeakTests: XCTestCase {
    func testOppositePhaseStereoRemainsAudible() {
        XCTAssertEqual(measure([[0.1, -0.1]], channels: 2), 0.1)
    }

    func testNonInterleavedRightChannelIsMeasured() {
        XCTAssertEqual(measure([[0, 0], [0.2, -0.3]]), 0.3)
    }

    func testPeakBeyondFormerScratchCapacityIsMeasured() {
        XCTAssertEqual(measure([Array(repeating: 0, count: 4096) + [0.4]]), 0.4)
    }

    func testEmptyAndNonFiniteSamplesDoNotHideValidPeak() {
        XCTAssertEqual(measure([[], [.nan, .infinity, -.infinity]]), 0)
        XCTAssertEqual(measure([[.nan, .infinity, -0.25]]), 0.25)
    }

    private func measure(_ channelsOfSamples: [[Float]], channels: UInt32 = 1) -> Float {
        let buffers = AudioBufferList.allocate(maximumBuffers: channelsOfSamples.count)
        var allocations: [UnsafeMutablePointer<Float>] = []
        defer {
            allocations.forEach { $0.deallocate() }
            buffers.unsafeMutablePointer.deallocate()
        }
        for (index, samples) in channelsOfSamples.enumerated() {
            let data = UnsafeMutablePointer<Float>.allocate(capacity: max(1, samples.count))
            allocations.append(data)
            for (offset, sample) in samples.enumerated() { data[offset] = sample }
            buffers[index] = AudioBuffer(
                mNumberChannels: channels,
                mDataByteSize: UInt32(samples.count * MemoryLayout<Float>.size),
                mData: UnsafeMutableRawPointer(data)
            )
        }
        return ProcessAudioLevelProbe.peak(in: UnsafePointer(buffers.unsafeMutablePointer))
    }
}
