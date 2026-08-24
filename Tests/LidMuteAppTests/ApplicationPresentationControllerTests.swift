import Foundation
import Testing
@testable import LidMuteApp

@MainActor @Test
func enabledLoginItemDoesNotPromptOrOpenSettings() {
    var promptCount = 0
    var openSettingsCount = 0
    let controller = ApplicationPresentationController(
        isLoginItemEnabled: { true },
        presentLoginItemPrompt: {
            promptCount += 1
            return true
        },
        openLoginItemSettings: { openSettingsCount += 1 }
    )

    controller.promptForLoginItemRegistrationIfNeeded()

    #expect(promptCount == 0)
    #expect(openSettingsCount == 0)
}

@MainActor @Test
func deferredLoginItemPromptDoesNotOpenSettings() {
    var promptCount = 0
    var openSettingsCount = 0
    let controller = ApplicationPresentationController(
        isLoginItemEnabled: { false },
        presentLoginItemPrompt: {
            promptCount += 1
            return false
        },
        registerLoginItem: {},
        openLoginItemSettings: { openSettingsCount += 1 }
    )

    controller.promptForLoginItemRegistrationIfNeeded()

    #expect(promptCount == 1)
    #expect(openSettingsCount == 0)
}

@MainActor @Test
func acceptedLoginItemPromptRegistersWithoutOpeningSettings() {
    var promptCount = 0
    var registerCount = 0
    var openSettingsCount = 0
    let controller = ApplicationPresentationController(
        isLoginItemEnabled: { false },
        presentLoginItemPrompt: {
            promptCount += 1
            return true
        },
        registerLoginItem: { registerCount += 1 },
        openLoginItemSettings: { openSettingsCount += 1 }
    )

    controller.promptForLoginItemRegistrationIfNeeded()

    #expect(promptCount == 1)
    #expect(registerCount == 1)
    #expect(openSettingsCount == 0)
}

@MainActor @Test
func failedLoginItemRegistrationOpensSettings() {
    var openSettingsCount = 0
    let controller = ApplicationPresentationController(
        isLoginItemEnabled: { false },
        presentLoginItemPrompt: { true },
        registerLoginItem: { throw NSError(domain: "test", code: 1) },
        openLoginItemSettings: { openSettingsCount += 1 }
    )

    controller.promptForLoginItemRegistrationIfNeeded()

    #expect(openSettingsCount == 1)
}
