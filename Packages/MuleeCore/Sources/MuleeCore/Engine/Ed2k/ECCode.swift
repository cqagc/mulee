// Wire constants from aMule 3.1.0 ECCodes.abstract (protocol 0x0204).
enum ECCode {
    enum Op {
        static let noop: UInt8 = 0x01
        static let authRequest: UInt8 = 0x02
        static let authFail: UInt8 = 0x03
        static let authOK: UInt8 = 0x04
        static let failed: UInt8 = 0x05
        static let shutdown: UInt8 = 0x08
        static let addLink: UInt8 = 0x09
        static let getConnectionState: UInt8 = 0x0B
        static let miscData: UInt8 = 0x07
        static let getDownloads: UInt8 = 0x0D
        static let downloads: UInt8 = 0x1F
        static let getShared: UInt8 = 0x10
        static let shared: UInt8 = 0x22
        static let pause: UInt8 = 0x19
        static let resume: UInt8 = 0x1A
        static let delete: UInt8 = 0x1D
        static let getPreferences: UInt8 = 0x3F
        static let setPreferences: UInt8 = 0x40
        static let createCategory: UInt8 = 0x41
        static let serverUpdate: UInt8 = 0x32
        static let kadUpdate: UInt8 = 0x4D
        static let serverConnect: UInt8 = 0x2F
        static let kadStart: UInt8 = 0x48
        static let authSalt: UInt8 = 0x4F
        static let authPassword: UInt8 = 0x50
        static let getUpdate: UInt8 = 0x52
    }

    enum Tag {
        static let string: UInt16 = 0x0000
        static let passwordHash: UInt16 = 0x0001
        static let protocolVersion: UInt16 = 0x0002
        static let detail: UInt16 = 0x0004
        static let connectionState: UInt16 = 0x0005
        static let ed2kID: UInt16 = 0x0006
        static let passwordSalt: UInt16 = 0x000B
        static let canZlib: UInt16 = 0x000C
        static let canUTF8: UInt16 = 0x000D
        static let clientName: UInt16 = 0x0100
        static let clientVersion: UInt16 = 0x0101
        static let partFile: UInt16 = 0x0300
        static let name: UInt16 = 0x0301
        static let size: UInt16 = 0x0303
        static let received: UInt16 = 0x0306
        static let speed: UInt16 = 0x0307
        static let status: UInt16 = 0x0308
        static let sources: UInt16 = 0x030A
        static let transferringSources: UInt16 = 0x030D
        static let category: UInt16 = 0x030F
        static let lastComplete: UInt16 = 0x0311
        static let stopped: UInt16 = 0x0317
        static let fileHash: UInt16 = 0x031E
        static let knownFile: UInt16 = 0x0400
        static let filename: UInt16 = 0x0408
        static let completeSources: UInt16 = 0x040D
        static let filePath: UInt16 = 0x0416
        static let uploadSpeed: UInt16 = 0x0417
        static let server: UInt16 = 0x0500
        static let serverName: UInt16 = 0x0501
        static let client: UInt16 = 0x0600
        static let queueRank: UInt16 = 0x061A
        static let requestFile: UInt16 = 0x0620
        static let selectPreferences: UInt16 = 0x1000
        static let categories: UInt16 = 0x1100
        static let categoryEntry: UInt16 = 0x1101
        static let categoryTitle: UInt16 = 0x1102
        static let categoryPath: UInt16 = 0x1103
        static let categoryComment: UInt16 = 0x1104
        static let categoryColor: UInt16 = 0x1105
        static let categoryPriority: UInt16 = 0x1106
        static let connectionPreferences: UInt16 = 0x1300
        static let downloadLimit: UInt16 = 0x1303
        static let uploadLimit: UInt16 = 0x1304
        static let tcpPort: UInt16 = 0x1306
        static let udpPort: UInt16 = 0x1307
        static let udpDisabled: UInt16 = 0x1308
        static let autoconnect: UInt16 = 0x130B
        static let reconnect: UInt16 = 0x130C
        static let ed2kEnabled: UInt16 = 0x130D
        static let kadEnabled: UInt16 = 0x130E
        static let directoryPreferences: UInt16 = 0x1A00
        static let incomingDirectory: UInt16 = 0x1A01
    }
}
