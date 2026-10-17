import Foundation
import Testing
@testable import MuleeCore

struct HTTPFeatureTests {
    @Test func unauthorizedStateOffersCredentialsOnlyForFailedAuthentication() {
        let message = HTTPDownloadFailure.needsLogin.localizedDescription
        #expect(HTTPDownloadFailure.requiresCredentials(status: .failed, message: message))
        #expect(!HTTPDownloadFailure.requiresCredentials(status: .downloading, message: message))
        #expect(!HTTPDownloadFailure.requiresCredentials(status: .failed, message: HTTPDownloadFailure.expiredLink.localizedDescription))
        #expect(Aria2ErrorDescriptions.message(for: "24") == message)
        #expect(Aria2ErrorDescriptions.message(for: "22", detail: "status=401") == message)
    }

    @Test func authenticationLookupRequiresTheTaskMarkerAndKeepsTheOriginalHost() throws {
        let url = try #require(URL(string: "https://example.org/example.bin"))
        let credential = HTTPCredentialStore.Credential(username: "user", password: "password")
        var hosts: [String] = []
        var context = DownloadRequestContext()
        let load: (String) -> HTTPCredentialStore.Credential? = { host in
            hosts.append(host)
            return credential
        }
        #expect(try HTTPResourceProbe.authenticatedContext(url, context: context, credentialLoader: load).headers["Authorization"] == nil)
        #expect(hosts.isEmpty)
        context.usesStoredHTTPCredentials = true
        #expect(try HTTPResourceProbe.authenticatedContext(url, context: context, credentialLoader: load).headers["Authorization"] == credential.authorization)
        #expect(hosts == ["example.org"])
    }

    @Test func authenticationMarkerPersistsWithoutTheAuthorizationHeader() throws {
        var context = DownloadRequestContext(headers: ["Authorization": "Basic private-value"])
        context.usesStoredHTTPCredentials = true
        let data = try JSONEncoder().encode(context)
        #expect(!String(decoding: data, as: UTF8.self).contains("private-value"))
        let restored = try JSONDecoder().decode(DownloadRequestContext.self, from: data)
        #expect(restored.usesStoredHTTPCredentials == true)
        #expect(restored.headers["Authorization"] == nil)
        #expect(try JSONDecoder().decode(DownloadRequestContext.self, from: Data("{\"headers\":{}}".utf8)).usesStoredHTTPCredentials == nil)
    }

    @Test(arguments: ["SSL/TLS handshake failure: certificate verification failed", "SSL peer certificate cannot be authenticated",
                      "certificate has expired", "certificate_verify_failed", "Cert verify failed: hostname mismatch",
                      "Invalid certificate chain", "Invalid certificate format", "Self-signed certificate", "No root certificate",
                      "Certificate expired", "Certificate not yet valid", "Invalid hostname"])
    func certificateFailuresDoNotExposeRawDetails(_ detail: String) {
        #expect(Aria2ErrorDescriptions.message(for: "1", detail: detail) == HTTPDownloadFailure.invalidCertificate.localizedDescription)
    }

    @Test func ordinaryNetworkAndHTTPFailuresRemainDistinctFromCertificates() {
        #expect(Aria2ErrorDescriptions.message(for: "6", detail: "connection reset https://example.org/certificate") != HTTPDownloadFailure.invalidCertificate.localizedDescription)
        #expect(HTTPDownloadFailure.isCertificateError(URLError(.serverCertificateUntrusted)))
        #expect(!HTTPDownloadFailure.isCertificateError(URLError(.timedOut)))
    }

    @Test(arguments: ["https://example.org/files.meta4", "https://example.org/files.METALINK?token=example",
                      "file:///tmp/example%20files.meta4", "/tmp/example files.metalink"])
    func metalinkRecognizesLinksAndLocalFiles(_ text: String) throws {
        let link = try #require(LinkParser.parse(text).first)
        guard case .http(let url, _, _) = link else {
            Issue.record("Metalink 必须交给 HTTP 引擎")
            return
        }
        #expect(HTTPMetalink.recognizes(url))
        #expect(link.kind == .http)
    }

    @Test func rejectsUnrelatedMetalinkNamesAndRemoteFileShares() throws {
        #expect(!HTTPMetalink.recognizes(try #require(URL(string: "https://example.org/files.meta4/"))))
        #expect(!HTTPMetalink.recognizes(try #require(URL(string: "https://example.org/files.meta4.zip"))))
        #expect(LinkParser.parse("file://other.example.org/files.meta4").isEmpty)
    }

    @Test func mirrorsRequireKnownMatchingSizeAndAvailableETag() throws {
        let original = HTTPResourceIdentity(size: 1234, etag: "v1")
        try original.validateReplacement(.init(size: 1234, etag: "v1"))
        try HTTPResourceIdentity(size: 1234).validateReplacement(.init(size: 1234))
        #expect(throws: HTTPDownloadFailure.resourceChanged) { try original.validateReplacement(.init(size: 1235, etag: "v1")) }
        #expect(throws: HTTPDownloadFailure.resourceChanged) { try original.validateReplacement(.init(size: 1234, etag: "v2")) }
        #expect(throws: HTTPDownloadFailure.unknownIdentity) { try original.validateReplacement(.init(size: nil, etag: "v1")) }
        #expect(throws: HTTPDownloadFailure.unknownIdentity) { try original.validateReplacement(.init(size: 1234)) }
    }

    @Test(arguments: [("00", 0), ("80", 10), ("a0", 10), ("c0", 20), ("e0", 30), ("f0", 40),
                      ("f8", 45), ("FF", 45), ("70", 0), ("d0", 20), ("f7", 40), ("", 0), ("g0", 0), ("f", 0)])
    func contiguousBitfieldStopsAtFirstGapAndClipsLastPiece(_ bits: String, _ expected: Int) {
        #expect(HTTPStreamingProgress.contiguousBytes(bitfield: bits, numPieces: 5, pieceLength: 10, totalLength: 45) == Int64(expected))
    }

    @Test func bitfieldHandlesPaddingInvalidGeometryAndOverflow() {
        #expect(HTTPStreamingProgress.contiguousBytes(bitfield: "80", numPieces: 1, pieceLength: 10, totalLength: 3) == 3)
        #expect(HTTPStreamingProgress.contiguousBytes(bitfield: "ff", numPieces: 8, pieceLength: .max, totalLength: .max) == .max)
        #expect(HTTPStreamingProgress.contiguousBytes(bitfield: "ff", numPieces: 0, pieceLength: 10, totalLength: 45) == 0)
        #expect(HTTPStreamingProgress.contiguousBytes(bitfield: "ff", numPieces: 5, pieceLength: 0, totalLength: 45) == 0)
        #expect(HTTPStreamingProgress.contiguousBytes(bitfield: "ff", numPieces: 5, pieceLength: 10, totalLength: -1) == 0)
        #expect(HTTPStreamingProgress.contiguousBytes(bitfield: "ff", numPieces: .max, pieceLength: 10, totalLength: 45) == 0)
    }
}
