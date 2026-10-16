import AppKit
import Foundation
import ServiceManagement
import Testing
@testable import Mulee

@Suite @MainActor struct SettingsLoginItemTests {
    private final class Service: LoginItemProviding {
        var status: SMAppService.Status = .notRegistered
        var approvalNeeded = false
        var fails = false
        var registered = 0
        var unregistered = 0
        var opened = 0
        func register() throws {
            if fails { throw NSError(domain: "SettingsTest", code: 1) }
            registered += 1
            status = approvalNeeded ? .requiresApproval : .enabled
        }
        func unregister() throws {
            if fails { throw NSError(domain: "SettingsTest", code: 2) }
            unregistered += 1
            status = .notRegistered
        }
        func openSettings() {
            opened += 1
        }
    }

    @Test func recognizesLoginLaunchWithoutOpeningARealWindow() {
        let event = NSAppleEventDescriptor.appleEvent(
            withEventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEOpenApplication),
            targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID)
        )
        #expect(!AppDelegate.isLoginLaunch(event))
        event.setParam(NSAppleEventDescriptor(enumCode: keyAELaunchedAsLogInItem), forKeyword: keyAEPropData)
        #expect(AppDelegate.isLoginLaunch(event))
        #expect(!AppDelegate.isLoginLaunch(nil))
    }

    @Test func reflectsSystemStateApprovalFailureAndUnregister() throws {
        let temporaryDefaults = try TemporaryDefaults(prefix: "SettingsLogin-")
        defer { temporaryDefaults.clean() }
        let defaults = temporaryDefaults.defaults
        let settings = SettingsModel(defaults: defaults)
        let service = Service()
        let controller = LoginItemController(service: service)
        settings.launchAtLogin = true
        controller.refresh(settings: settings)
        #expect(!settings.launchAtLogin)
        #expect(service.registered == 0)
        service.approvalNeeded = true
        controller.setEnabled(true, settings: settings)
        #expect(controller.requiresApproval)
        #expect(!controller.isEnabled)
        #expect(controller.isRegistered)
        controller.setEnabled(false, settings: settings)
        #expect(!controller.isRegistered)
        #expect(service.unregistered == 1)
        controller.setEnabled(true, settings: settings)
        controller.openSettings()
        #expect(service.opened == 1)
        service.status = .enabled
        controller.refresh(settings: settings)
        #expect(settings.launchAtLogin)
        service.fails = true
        controller.setEnabled(false, settings: settings)
        #expect(controller.issue != nil)
        #expect(controller.isEnabled)
        service.fails = false
        controller.setEnabled(false, settings: settings)
        #expect(service.unregistered == 2)
        #expect(!controller.isEnabled)
        service.fails = true
        controller.setEnabled(true, settings: settings)
        #expect(controller.issue != nil)
        #expect(!settings.launchAtLogin)
    }
}
