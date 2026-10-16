import Foundation

// Nested wire types share one namespace and never cross the public engine contract.
enum Aria2RPCModels: Sendable {
    struct Request: Encodable, Sendable {
        let jsonrpc = "2.0"
        let id: String
        let method: String
        let params: [Aria2RPCValue]
    }

    struct Response<Result: Decodable & Sendable>: Decodable, Sendable {
        let id: String?
        let jsonrpc: String?
        let result: Result?
        let error: Failure?
    }

    struct Failure: Decodable, Sendable {
        let code: Int
        let message: String
    }

    struct URI: Decodable, Sendable {
        let uri: String
    }

    struct File: Decodable, Sendable {
        let path: String
        let uris: [URI]?
    }

    struct Status: Decodable, Sendable {
        let gid: String
        let status: String
        let dir: String?
        let totalLength: String?
        let completedLength: String?
        let downloadSpeed: String?
        let uploadSpeed: String?
        let connections: String?
        let errorCode: String?
        let errorMessage: String?
        let files: [File]?

        static let keys = [
            "gid", "status", "dir", "totalLength", "completedLength", "downloadSpeed",
            "uploadSpeed", "connections", "errorCode", "errorMessage", "files"
        ]
    }
}
