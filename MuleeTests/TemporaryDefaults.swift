import Foundation
import Synchronization
import Testing

final class TemporaryDefaults {
    static let sweepPrefix = "mulee.tests."
    let name: String
    let defaults: UserDefaults
    private let cleaned = Mutex(false)

    init(prefix: String) throws {
        // 统一前缀，测试结束后 scheme 的收尾动作按它清理残留文件。
        name = Self.sweepPrefix + prefix + UUID().uuidString
        defaults = try #require(UserDefaults(suiteName: name))
    }

    nonisolated func clean() {
        guard cleaned.withLock({ cleaned in
            defer { cleaned = true }
            return !cleaned
        }) else {
            return
        }
        UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
        // cfprefsd may still write an empty file later; the scheme's post-test action sweeps those.
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences")
            .appendingPathComponent(name + ".plist")
        try? FileManager.default.removeItem(at: file)
    }

    deinit {
        clean()
    }
}

@Suite @MainActor struct TemporaryDefaultsTests {
    // cfprefsd may write an empty file back after removal; the scheme post-action sweeps it,
    // so only the domain contents are checked here.
    @Test func removesPersistedDomainWhenScopeThrows() async throws {
        enum ExpectedError: Error {
            case stop
        }
        var name = ""
        func writeAndThrow() throws {
            let temporaryDefaults = try TemporaryDefaults(prefix: "mulee.defaults-cleanup.")
            defer { temporaryDefaults.clean() }
            name = temporaryDefaults.name
            temporaryDefaults.defaults.set("persisted", forKey: "value")
            #expect(temporaryDefaults.defaults.synchronize())
            throw ExpectedError.stop
        }

        #expect(throws: ExpectedError.self) { try writeAndThrow() }
        let reloaded = try #require(UserDefaults(suiteName: name))
        #expect(reloaded.persistentDomain(forName: name)?.isEmpty != false)
        #expect(name.hasPrefix(TemporaryDefaults.sweepPrefix))
    }
}
