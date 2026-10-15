import Foundation

struct Aria2RPCClient: Sendable {
    let endpoint: URL
    let secret: String
    let session: URLSession

    init(port: UInt16, secret: String) throws {
        guard let endpoint = URL(string: "http://127.0.0.1:\(port)/jsonrpc") else {
            throw EngineError.invalidResponse("RPC 地址无效")
        }
        self.endpoint = endpoint
        self.secret = secret
        self.session = URLSession(configuration: Self.sessionConfiguration())
    }

    static func sessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 1
        configuration.timeoutIntervalForResource = 2
        return configuration
    }

    func call<Result: Decodable & Sendable>(
        _ method: String,
        _ params: [Aria2RPCValue] = [],
        as type: Result.Type = Result.self
    ) async throws -> Result {
        let id = UUID().uuidString
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Aria2RPCModels.Request(
            id: id, method: method, params: [.string("token:\(secret)")] + params
        ))
        let (data, response) = try await session.data(for: request)
        let decoded: Aria2RPCModels.Response<Result>
        do {
            decoded = try JSONDecoder().decode(Aria2RPCModels.Response<Result>.self, from: data)
        } catch {
            throw EngineError.invalidResponse("无法解析 aria2 RPC 响应：\(error.localizedDescription)")
        }
        if let error = decoded.error { throw EngineError.rpc(code: error.code, message: error.message) }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              decoded.id == id, decoded.jsonrpc == "2.0", let result = decoded.result else {
            throw EngineError.invalidResponse("aria2 RPC 响应不完整")
        }
        return result
    }
}
