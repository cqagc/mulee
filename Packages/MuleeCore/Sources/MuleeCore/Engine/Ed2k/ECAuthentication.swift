import CryptoKit
import Foundation

/// 3.1.0 RemoteConnect.cpp：MD5(lowercase(passwordMD5) + MD5(uppercaseHex(salt)))。
enum ECAuthentication {
    static func passwordHash(_ password: String) -> String {
        ECTag.hex(Data(Insecure.MD5.hash(data: Data(password.utf8)))).lowercased()
    }

    static func response(password: String, salt: UInt64) -> Data {
        let saltHash = passwordHash(String(salt, radix: 16, uppercase: true))
        let challenge = passwordHash(password) + saltHash
        return Data(Insecure.MD5.hash(data: Data(challenge.utf8)))
    }
}
