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

@Test func stableDefaultDeviceListChangePublishesWhileWaitingForRecovery() {
    var gate = AudioRouteChangeGate(lastDefaultOutputID: 41)
    gate.recordDeviceListChange()

    let deviceReconnect = gate.shouldPublish(
        currentDefaultOutputID: 41,
        reportDeviceListChanges: true
    )

    #expect(deviceReconnect)
}

@Test func stableDefaultDeviceListChangeIsIgnoredWhenReady() {
    var gate = AudioRouteChangeGate(lastDefaultOutputID: 41)
    gate.recordDeviceListChange()

    let aggregateNoise = gate.shouldPublish(
        currentDefaultOutputID: 41,
        reportDeviceListChanges: false
    )

    #expect(!aggregateNoise)
}

@Test func pendingDefaultTaskMergesDeviceListChangeForRecovery() {
    var gate = AudioRouteChangeGate(lastDefaultOutputID: 41)

    // The default-output task is pending; a devices callback records its bit
    // before that task evaluates the batch. Repeated devices callbacks remain
    // coalesced without losing the recovery signal.
    gate.recordDeviceListChange()
    gate.recordDeviceListChange()

    let firstPublished = gate.shouldPublish(
        currentDefaultOutputID: 41,
        reportDeviceListChanges: true
    )
    let secondPublished = gate.shouldPublish(
        currentDefaultOutputID: 41,
        reportDeviceListChanges: true
    )
    #expect(firstPublished)
    #expect(!secondPublished)
}

@Test func disablingDeviceReportingBeforePendingBatchUsesDefaultGate() {
    var gate = AudioRouteChangeGate(lastDefaultOutputID: 41)
    // A device event was queued while recovery mode was enabled, then
    // startAll() switches mode off before the pending batch is evaluated.
    gate.recordDeviceListChange()

    let staleDeviceSignal = gate.shouldPublish(
        currentDefaultOutputID: 41,
        reportDeviceListChanges: false
    )
    let afterReenable = gate.shouldPublish(
        currentDefaultOutputID: 41,
        reportDeviceListChanges: true
    )

    #expect(!staleDeviceSignal)
    #expect(!afterReenable)
}

@Test func stoppingClearsPendingDeviceListChange() {
    var gate = AudioRouteChangeGate(lastDefaultOutputID: 41)
    gate.recordDeviceListChange()
    gate = AudioRouteChangeGate()
    _ = gate.shouldPublish(currentDefaultOutputID: 41)

    let published = gate.shouldPublish(
        currentDefaultOutputID: 41,
        reportDeviceListChanges: true
    )
    #expect(!published)
}

@Test func forcedDeviceChangeUpdatesDefaultBaseline() {
    var gate = AudioRouteChangeGate(lastDefaultOutputID: 41)
    gate.recordDeviceListChange()

    let forcedPublish = gate.shouldPublish(
        currentDefaultOutputID: 72,
        reportDeviceListChanges: true
    )
    let repeatedDefault = gate.shouldPublish(currentDefaultOutputID: 72)

    #expect(forcedPublish)
    #expect(!repeatedDefault)
}

@Test func deviceReconnectPublishesWhenDefaultOutputIsUnavailable() {
    var gate = AudioRouteChangeGate(lastDefaultOutputID: 41)
    gate.recordDeviceListChange()

    let published = gate.shouldPublish(
        currentDefaultOutputID: nil,
        reportDeviceListChanges: true
    )

    #expect(published)
}
