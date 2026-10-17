import AppKit
import Foundation
import Testing
import UserNotifications
@testable import Mulee

@Suite struct DockPresenterTests {
    @Test func badgeWarningIncludesSystemNotificationAndBadgePermissions() {
        #expect(DockPresenter.badgePermissionDenied(badge: .disabled, authorization: .authorized))
        #expect(DockPresenter.badgePermissionDenied(badge: .enabled, authorization: .denied))
        #expect(!DockPresenter.badgePermissionDenied(badge: .enabled, authorization: .authorized))
        #expect(!DockPresenter.badgePermissionDenied(badge: .notSupported, authorization: .notDetermined))
    }

    @Test func activeCountAndEmptyStates() {
        #expect(DockPresenter.badge(.none, activeCount: 3, bytesPerSecond: 12_000_000) == nil)
        #expect(DockPresenter.badge(.active, activeCount: 3, bytesPerSecond: 0) == "3")
        #expect(DockPresenter.badge(.active, activeCount: 0, bytesPerSecond: 0) == nil)
        #expect(DockPresenter.badge(.active, activeCount: -1, bytesPerSecond: 0) == nil)
        #expect(DockPresenter.badge(.speed, activeCount: 1, bytesPerSecond: 0) == nil)
        #expect(DockPresenter.badge(.speed, activeCount: 1, bytesPerSecond: -1) == nil)
    }

    @Test func speedUsesCompactUnits() {
        #expect(DockPresenter.badge(.speed, activeCount: 1, bytesPerSecond: 12_000_000) == "12M")
        #expect(DockPresenter.badge(.speed, activeCount: 1, bytesPerSecond: 1_500_000) == "1.5M")
        #expect(DockPresenter.badge(.speed, activeCount: 1, bytesPerSecond: 500) == "500")
        #expect(DockPresenter.badge(.speed, activeCount: 1, bytesPerSecond: 999_000) == "999K")
        #expect(DockPresenter.badge(.speed, activeCount: 1, bytesPerSecond: 2_000_000_000) == "2.0G")
    }

    @Test @MainActor func menuHasFourActionsAndReflectsSlowMode() throws {
        let storage = try TemporaryDefaults(prefix: "DockMenu-")
        defer { storage.clean() }
        let model = AppModel(tasks: [], preventsSleepWhileDownloading: false)
        let delegate = AppDelegate()
        delegate.configure(model: model, settings: SettingsModel(defaults: storage.defaults), usesSampleData: true)
        model.isSlowModeActive = true
        let menu = try #require(delegate.applicationDockMenu(NSApplication.shared))
        #expect(menu.items.map(\.title) == [String(localized: "新建下载"), String(localized: "暂停全部"), String(localized: "继续全部"), String(localized: "慢速模式")])
        #expect(menu.items.allSatisfy { $0.target === delegate && $0.action != nil })
        #expect(menu.items[3].state == .on)
        model.isSlowModeActive = false
        #expect(delegate.applicationDockMenu(NSApplication.shared)?.items[3].state == .off)
    }

    @Test @MainActor func settingDefaultsPersistenceAndInvalidStoredValue() throws {
        let storage = try TemporaryDefaults(prefix: "DockBadge-")
        defer { storage.clean() }
        let settings = SettingsModel(defaults: storage.defaults)
        #expect(settings.dockBadge == .active)
        settings.dockBadge = .speed
        #expect(SettingsModel(defaults: storage.defaults).dockBadge == .speed)
        storage.defaults.set("unknown", forKey: SettingsModel.Key.dockBadge)
        #expect(SettingsModel(defaults: storage.defaults).dockBadge == .active)
    }
}
