import CoreAudio
import Testing
@testable import LidMuteApp

@Test func repeatedDeviceNotificationsWithoutDefaultOutputChangeAreIgnored() {
    var gate = AudioRouteChangeGate(lastDefaultOutputID: 41)

    let firstRepeat = gate.shouldPublish(currentDefaultOutputID: 41)
    let secondRepeat = gate.shouldPublish(currentDefaultOutputID: 41)
    let changed = gate.shouldPublish(currentDefaultOutputID: 72)
    let finalRepeat = gate.shouldPublish(currentDefaultOutputID: 72)

    #expect(!firstRepeat)
    #expect(!secondRepeat)
    #expect(changed)
    #expect(!finalRepeat)
}
