import AppKit
import UniformTypeIdentifiers

enum DefaultHandlerKind: String, CaseIterable, Identifiable {
    case magnet, ed2k, thunder, torrent

    var id: Self { self }
    var title: String { self == .torrent ? ".torrent" : rawValue }

    var applicationURL: URL? {
        if self == .torrent {
            return NSWorkspace.shared.urlForApplication(toOpen: Self.torrentType)
        }
        guard let url = URL(string: rawValue + "://") else { return nil }
        return NSWorkspace.shared.urlForApplication(toOpen: url)
    }

    var applicationName: String {
        guard let url = applicationURL else { return "尚未设置" }
        return FileManager.default.displayName(atPath: url.path)
    }

    func setMulee() async throws {
        if self == .torrent {
            try await NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpen: Self.torrentType)
        } else {
            try await NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpenURLsWithScheme: rawValue)
        }
    }

    private static var torrentType: UTType {
        UTType(importedAs: "org.bittorrent.torrent", conformingTo: .data)
    }
}
