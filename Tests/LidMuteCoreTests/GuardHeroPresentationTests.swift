import XCTest
@testable import LidMuteCore

final class GuardHeroPresentationTests: XCTestCase {
    func testBlockedRecoveryUsesVisibleHighPriorityStatusAndDisablesAction() {
        let presentation = GuardHeroPresentation(
            lifecycleState: .recoveryBlocked(.corruptSnapshot),
            isEnabled: false,
            isNightProtectionActive: false,
            statusText: "扬声器恢复记录损坏，守卫已阻止启动"
        )

        XCTAssertEqual(presentation.eyebrow, "需要处理")
        XCTAssertEqual(presentation.title, "守卫暂不可用")
        XCTAssertEqual(presentation.subtitle, "扬声器恢复记录损坏，守卫已阻止启动")
        XCTAssertFalse(presentation.canToggleGuard)
    }

    func testRecoveringUsesVisibleRecoveryStatusAndDisablesAction() {
        let presentation = GuardHeroPresentation(
            lifecycleState: .recovering,
            isEnabled: false,
            isNightProtectionActive: false,
            statusText: "正在确认关机恢复结果"
        )

        XCTAssertEqual(presentation.eyebrow, "正在恢复")
        XCTAssertEqual(presentation.subtitle, "正在确认关机恢复结果")
        XCTAssertFalse(presentation.canToggleGuard)
    }

    func testShutdownTimeoutIsExplicitAndDisablesAction() {
        let presentation = GuardHeroPresentation(
            lifecycleState: .shutdownUnresolved,
            isEnabled: false,
            isNightProtectionActive: false,
            statusText: "关机恢复仍在进行，守卫操作已暂时停用"
        )

        XCTAssertEqual(presentation.eyebrow, "恢复未完成")
        XCTAssertEqual(presentation.title, "正在确认关机恢复结果")
        XCTAssertFalse(presentation.canToggleGuard)
    }
}
