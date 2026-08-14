import Foundation
import Testing
@testable import LidMuteCore

private func event(_ sequence: UInt64) -> LidMuteEvent {
    LidMuteEvent(sequence: sequence, kind: .chromeTabAudible, detail: "event-\(sequence)")
}

private func withTemporaryDirectory<T>(_ body: (URL) throws -> T) throws -> T {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "lidmute-bounded-events-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    return try body(root)
}

private func seedEvents(_ range: Range<Int>, at url: URL) throws {
    var data = Data()
    for value in range {
        data.append(try JSONEncoder().encode(event(UInt64(value))))
        data.append(0x0A)
    }
    try data.write(to: url)
}

@Test(arguments: [0, 1, 4_999, 5_000, 5_001, 10_000])
func storeRetainsNewestFiveThousandAcrossRestart(total: Int) throws {
    try withTemporaryDirectory { root in
        let url = root.appending(path: "events.jsonl")
        let store = BoundedJSONLineEventStore(url: url, maximumCount: 5_000)
        if total > 0 {
            try seedEvents(0..<(total - 1), at: url)
            _ = try store.appendReporting(event(UInt64(total - 1)))
        }

        let reopened = BoundedJSONLineEventStore(url: url, maximumCount: 5_000)
        let recent = try reopened.recent(limit: 5_000)

        #expect(recent.count == min(total, 5_000))
        #expect(recent.first?.sequence == (total == 0 ? nil : UInt64(max(0, total - 5_000))))
        #expect(recent.last?.sequence == (total == 0 ? nil : UInt64(total - 1)))
    }
}

@Test
func corruptionIsReportedInsteadOfSilentlySkipped() throws {
    try withTemporaryDirectory { root in
        let url = root.appending(path: "events.jsonl")
        try Data("not-json\n".utf8).write(to: url)
        let store = BoundedJSONLineEventStore(url: url, maximumCount: 5_000)

        #expect(throws: EventStoreError.corruptRecord(line: 1)) {
            try store.recent(limit: 5_000)
        }
        #expect(store.health == .corruptRecord(line: 1))
    }
}
