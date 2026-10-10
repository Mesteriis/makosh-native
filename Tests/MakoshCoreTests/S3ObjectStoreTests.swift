import XCTest
import Foundation
import CryptoKit
import Darwin
@testable import MakoshCore

final class S3ObjectStoreTests: XCTestCase {
    private func config(_ endpoint: String = "http://127.0.0.1:19399") throws -> S3ObjectStoreConfiguration {
        try S3ObjectStoreConfiguration(endpoint: endpoint, region: "us-east-1", bucket: "synthetic-bucket",
            accessKeyID: "synthetic-access", secretAccessKey: "synthetic-secret")
    }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
        return url
    }
    private func digest(_ bytes: Data) -> String { S3Signer.hex(SHA256.hash(data: bytes)) }

    func testAWSOfficialGETSignatureVector() {
        // Public AWS example credentials, not a working account.
        // https://docs.aws.amazon.com/AmazonS3/latest/developerguide/sig-v4-header-based-auth.html
        let timestamp = "20130524T000000Z"
        let signature = S3Signer.authorization(method: "GET", path: "/test.txt",
            headers: ["host": "examplebucket.s3.amazonaws.com", "range": "bytes=0-9",
                      "x-amz-content-sha256": S3Signer.emptyHash, "x-amz-date": timestamp],
            payloadHash: S3Signer.emptyHash, timestamp: timestamp, region: "us-east-1",
            accessKey: "AKIAIOSFODNN7EXAMPLE", secret: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY")
        XCTAssertTrue(signature.hasSuffix("Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41"))
        XCTAssertTrue(signature.contains("SignedHeaders=host;range;x-amz-content-sha256;x-amz-date"))
    }

    func testAWSOfficialPUTSignatureVectorAndSignedMetadataChange() {
        let timestamp = "20130524T000000Z"
        let hash = "44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072"
        let headers = ["host": "examplebucket.s3.amazonaws.com", "date": "Fri, 24 May 2013 00:00:00 GMT",
            "x-amz-content-sha256": hash, "x-amz-date": timestamp, "x-amz-storage-class": "REDUCED_REDUNDANCY"]
        func signature(_ values: [String: String]) -> String {
            S3Signer.authorization(method: "PUT", path: "/test%24file.text", headers: values, payloadHash: hash,
                timestamp: timestamp, region: "us-east-1", accessKey: "AKIAIOSFODNN7EXAMPLE",
                secret: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY")
        }
        XCTAssertTrue(signature(headers).hasSuffix("Signature=98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd"))
        var metadata = headers; metadata["x-amz-meta-sha256"] = hash
        XCTAssertNotEqual(signature(headers), signature(metadata))
    }

    func testEndpointAndConfigurationValidationRejectsCredentialLeakPaths() throws {
        for endpoint in ["https://example.invalid", "https://example.invalid/", "http://localhost:1234", "http://[::1]:1234"] {
            _ = try config(endpoint)
        }
        for endpoint in ["http://example.invalid", "http://127.0.0.2", "ftp://localhost", "https://user:secret@example.invalid",
                         "https://example.invalid/prefix", "https://example.invalid/?secret=1", "https://example.invalid/#fragment",
                         "https://example.invalid/%2e", "https://example.invalid:0", "https://example.invalid\n"] {
            XCTAssertThrowsError(try config(endpoint)) { error in
                XCTAssertEqual(error as? S3ObjectStoreError, .configuration)
                XCTAssertFalse(error.localizedDescription.contains("secret"))
            }
        }
        let synthetic = Data("{\"endpoint\":\"synthetic-private-invalid\",\"secretAccessKey\":\"DO_NOT_ECHO\"}".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(S3ObjectStoreConfiguration.self, from: synthetic)) { error in
            XCTAssertFalse(error.localizedDescription.contains("DO_NOT_ECHO"))
            XCTAssertEqual(error as? S3ObjectStoreError, .configuration)
        }
        let original = try config()
        let decoded = try JSONDecoder().decode(S3ObjectStoreConfiguration.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded.endpoint, original.endpoint)
    }

    func testOpaqueKeysHashAndSizeAreBounded() throws {
        for key in ["objects/abc-123.def_456", "a", String(repeating: "a", count: 1024)] { try S3Signer.validateKey(key) }
        for key in ["", "/a", "a/", "a//b", ".", "..", "a/../b", "a/./b", "a%2Fb", "a?b", "a#b", "a\\b", "ключ", "a\n", String(repeating: "a", count: 1025)] {
            XCTAssertThrowsError(try S3Signer.validateKey(key))
        }
        try S3Signer.validateHash(S3Signer.emptyHash, count: 0)
        XCTAssertThrowsError(try S3Signer.validateHash(S3Signer.emptyHash.uppercased(), count: 0))
        XCTAssertThrowsError(try S3Signer.validateHash(S3Signer.emptyHash, count: -1))
        XCTAssertThrowsError(try S3Signer.validateHash(S3Signer.emptyHash, count: Int64.max))
    }

    func testRedirectDelegateRejectsEvenSameOriginAndCredentialBearingTarget() throws {
        let transfer = S3Transfer(limit: 0, download: false)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let original = try XCTUnwrap(URL(string: "https://example.invalid/object"))
        let task = session.dataTask(with: original) // Never resumed; no network.
        let response = try XCTUnwrap(HTTPURLResponse(url: original, statusCode: 307, httpVersion: "HTTP/1.1", headerFields: [:]))
        for target in [original, try XCTUnwrap(URL(string: "https://elsewhere.invalid/object"))] {
            var request = URLRequest(url: target); request.setValue("synthetic-secret", forHTTPHeaderField: "Authorization")
            var called = false
            transfer.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: request) { value in
                called = true; XCTAssertNil(value)
            }
            XCTAssertTrue(called)
        }
    }

    func testStreamingSnapshotPreservesSourceAndRejectsMismatchAndExclusiveDestination() async throws {
        let root = try directory(), source = root.appendingPathComponent("source")
        let bytes = Data(repeating: 0x39, count: 2 * 1024 * 1024 + 17)
        try bytes.write(to: source)
        let file = try await S3LocalFile.stage(source, hash: digest(bytes), count: Int64(bytes.count))
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let destination = root.appendingPathComponent("export")
        try Data("existing".utf8).write(to: destination)
        do { try await S3LocalFile.export(file, destination: destination, hash: digest(bytes), count: Int64(bytes.count)); XCTFail("Expected exclusive destination") }
        catch {}
        XCTAssertEqual(try Data(contentsOf: destination), Data("existing".utf8))
        let bad = root.appendingPathComponent("bad")
        do { try await S3LocalFile.export(file, destination: bad, hash: S3Signer.emptyHash, count: Int64(bytes.count)); XCTFail("Expected mismatch") }
        catch { XCTAssertEqual(error as? S3ObjectStoreError, .integrity) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: bad.path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".makosh-s3-") })
    }

    func testSpecialFilesAndPreCancellationFailWithoutReadingOrNetwork() async throws {
        let root = try directory(), source = root.appendingPathComponent("source")
        try Data([1]).write(to: source)
        let link = root.appendingPathComponent("link"), fifo = root.appendingPathComponent("fifo")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        for file in [link, fifo, root] {
            do { _ = try await S3LocalFile.stage(file, hash: digest(Data([1])), count: 1); XCTFail("Expected special-file rejection") }
            catch { XCTAssertTrue(error is S3ObjectStoreError) }
        }
        let hash = digest(Data([1]))
        let task = Task {
            try Task.checkCancellation()
            return try await S3LocalFile.stage(source, hash: hash, count: 1)
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError {} catch { XCTFail("Expected cancellation error") }
    }

    func testOptInSyntheticS3RoundTripAndConditionalConflict() async throws {
        guard let path = ProcessInfo.processInfo.environment["MAKOSH_TEST_S3_CONFIG"] else {
            throw XCTSkip("Set MAKOSH_TEST_S3_CONFIG for an explicitly configured synthetic S3 integration test")
        }
        // Direct config or ignored app wrapper; never print values or decoder diagnostics.
        struct Wrapper: Decodable { let s3: S3ObjectStoreConfiguration }
        let configuration: S3ObjectStoreConfiguration
        do {
            let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
            if let wrapper = try? JSONDecoder().decode(Wrapper.self, from: bytes) { configuration = wrapper.s3 }
            else { configuration = try JSONDecoder().decode(S3ObjectStoreConfiguration.self, from: bytes) }
        } catch { throw S3ObjectStoreError.configuration }
        let store = try S3ObjectStore(configuration: configuration)
        let root = try directory(), source = root.appendingPathComponent("synthetic")
        let bytes = Data(repeating: 0xa7, count: 1024 * 1024 + 13)
        try bytes.write(to: source)
        let key = "synthetic-tests/" + UUID().uuidString.lowercased()
        let hash = digest(bytes), count = Int64(bytes.count)
        let missing = try await store.head(key: key)
        XCTAssertNil(missing)
        let receipt = try await store.put(file: source, key: key, sha256: hash, byteCount: count)
        XCTAssertEqual(receipt.byteCount, count)
        let found = try await store.head(key: key)
        XCTAssertEqual(found, receipt)
        let repeated = try await store.put(file: source, key: key, sha256: hash, byteCount: count)
        XCTAssertEqual(repeated, receipt)
        let destination = root.appendingPathComponent("download")
        try await store.download(key: key, to: destination, sha256: hash, byteCount: count)
        XCTAssertEqual(try Data(contentsOf: destination), bytes)
        let different = Data([9]); try different.write(to: source)
        do { _ = try await store.put(file: source, key: key, sha256: digest(different), byteCount: 1); XCTFail("Expected immutable conflict") }
        catch { XCTAssertEqual(error as? S3ObjectStoreError, .conflict) }
    }
}
