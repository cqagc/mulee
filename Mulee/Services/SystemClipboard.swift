import AppKit

struct SystemClipboard: ClipboardReading {
    static let muleeType = NSPasteboard.PasteboardType("com.cqagc.mulee.clipboard")

    var changeCount: Int { NSPasteboard.general.changeCount }
    var typeNames: Set<String> { Set((NSPasteboard.general.types ?? []).map(\.rawValue)) }

    func plainText() -> String? {
        NSPasteboard.general.string(forType: .string)
    }

    static func write(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(Data(), forType: muleeType)
        return pasteboard.setString(text, forType: .string)
    }
}
