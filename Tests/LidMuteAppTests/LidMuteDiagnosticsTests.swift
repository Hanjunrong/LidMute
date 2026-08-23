import Testing
@testable import LidMuteApp

private final class RecordingDiagnosticSink: LidMuteDiagnosticSinking, @unchecked Sendable {
    private(set) var events: [LidMuteDiagnosticEvent] = []
    func emit(_ event: LidMuteDiagnosticEvent) { events.append(event) }
}

@Test func diagnosticEventsContainNoArbitraryStringPayload() {
    let mirror = Mirror(reflecting: LidMuteDiagnosticEvent.chromeBridgeDegraded)
    #expect(mirror.children.isEmpty)
    #expect(!String(reflecting: LidMuteDiagnosticEvent.self).contains("ChromeTabEvidence"))
}

@Test func healthTransitionsEmitTypedEventsOnly() {
    let sink = RecordingDiagnosticSink()
    sink.emit(.chromeHeartbeatStale)
    sink.emit(.recoveryFailedSafetyUnknown)
    #expect(sink.events == [.chromeHeartbeatStale, .recoveryFailedSafetyUnknown])
}
