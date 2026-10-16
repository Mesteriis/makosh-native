import XCTest
import NIOEmbedded
@testable import MakoshMail

final class MailProtocolTests: XCTestCase {
    func testSMTPStartTLSUsesExplicitCertificateAndSendsData() async throws {
        let fixture = try await Fixture(mode: "smtp", scenario: "starttls"); defer { fixture.close() }
        var config = fixture.config; config.smtpSecurity = .startTLS
        try await SMTPService(config: config, password: "synthetic", tlsCAFile: fixture.root.appendingPathComponent("cert.pem").path).send(from: "qa@example.invalid", fromName: nil, recipients: ["peer@example.invalid"], message: "Subject: QA\r\n\r\nBody")
        let data = try await fixture.count("data"); XCTAssertEqual(data, 1)
    }
    func testCancellationDuringSMTPAuthenticationNeverSendsData() async throws {
        let fixture = try await Fixture(mode: "smtp", scenario: "hold-auth-starttls"); defer { fixture.close() }
        var config = fixture.config; config.smtpSecurity = .startTLS
        let service = SMTPService(config: config, password: "synthetic", tlsCAFile: fixture.root.appendingPathComponent("cert.pem").path)
        let task = Task { try await service.send(from: "qa@example.invalid", fromName: nil, recipients: ["peer@example.invalid"], message: "Subject: Cancel\r\n\r\nBody") }
        for _ in 0..<100 { if FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("auth-held").path) { break }; try await Task.sleep(for: .milliseconds(10)) }
        task.cancel(); try Data("release".utf8).write(to: fixture.root.appendingPathComponent("release-auth"))
        do { try await task.value; XCTFail("Cancelled authentication must not submit") } catch {}
        let data = try await fixture.count("data"); XCTAssertEqual(data, 0)
    }
    func testDispatchCreatesResponsePromiseOnlyAfterCancellationAdmission() async throws {
        let loop=EmbeddedEventLoop(),admission=MailCommandDispatch()
        let promise=try admission.dispatch { loop.makePromise(of:Int.self) }
        promise.succeed(42)
        let value=try await promise.futureResult.get();XCTAssertEqual(value,42)
        admission.cancel()
        var constructed=false
        do {
            let rejected=try admission.dispatch { constructed=true;return loop.makePromise(of:Int.self) }
            rejected.fail(CancellationError());XCTFail("Cancelled dispatch cannot construct a response promise")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(constructed)
    }
    func testCancellationWhileSelectIsHeldCannotDispatchMove() async throws {
        let fixture=try await Fixture(mode:"imap",scenario:"hold-select");defer { fixture.close() }
        let service=IMAPService(config:fixture.config,password:"synthetic")
        try await service.connectAndLogin()
        let move=Task { try await service.move(uid:11,from:"INBOX",to:"Sent") }
        let held=fixture.root.appendingPathComponent("select-held")
        for _ in 0..<300 { if FileManager.default.fileExists(atPath:held.path) { break };try await Task.sleep(for:.milliseconds(10)) }
        XCTAssertTrue(FileManager.default.fileExists(atPath:held.path));move.cancel()
        try Data().write(to:fixture.root.appendingPathComponent("release-select"))
        do { try await move.value;XCTFail("Cancelled intent must not reach UID MOVE") } catch { XCTAssertTrue(error is CancellationError) }
        await service.disconnect()
        let count=try await fixture.count("move");XCTAssertEqual(count,0)
    }
    func testSMTPAcceptance() async throws {
        let fixture=try await Fixture(mode:"smtp",scenario:"accept");defer { fixture.close() }
        try await SMTPService(config:fixture.config,password:"synthetic").send(from:"qa@example.invalid",fromName:nil,recipients:["peer@example.invalid"],message:"Subject: Fixture\r\n\r\nbody\r\n.line")
        let count=try await fixture.count("data");XCTAssertEqual(count,1)
    }
    func testSMTPDataLongPartsHaveExactCRLFOnWire() async throws {
        let fixture = try await Fixture(mode: "smtp", scenario: "accept"); defer { fixture.close() }
        let raw = MIME.buildMessage(from: "qa@example.invalid", fromName: nil, to: "peer@example.invalid", subject: "Long", body: String(repeating: "Body ", count: 200), attachments: [.init(filename: "long.bin", mimeType: "application/octet-stream", data: Data(repeating: 123, count: 1024))])
        try await SMTPService(config: fixture.config, password: "synthetic").send(from: "qa@example.invalid", fromName: nil, recipients: ["peer@example.invalid"], message: raw)
        _ = try await fixture.count("data")
        let wire = try String(contentsOf: fixture.root.appendingPathComponent("data.eml"), encoding: .utf8)
        let stripped = wire.replacingOccurrences(of: "\r\n", with: "")
        XCTAssertFalse(stripped.contains("\r")); XCTAssertFalse(stripped.contains("\n"))
    }
    func testLocalizedMailboxWireNamesSurviveListAndSelect() async throws {
        let fixture = try await Fixture(mode: "imap", scenario: "localized"); defer { fixture.close() }
        let service = IMAPService(config: fixture.config, password: "synthetic")
        try await service.connectAndLogin()
        let boxes = try await service.listMailboxes()
        let localized = try XCTUnwrap(boxes.first { $0.displayName == "Привет" })
        XCTAssertEqual(localized.name, "&BB8EQAQ4BDIENQRC-")
        _ = try await service.select(localized.name)
        let ampersand = try XCTUnwrap(boxes.first { $0.displayName == "R&D" })
        XCTAssertEqual(ampersand.name, "R&-D"); _ = try await service.select(ampersand.name)
        await service.disconnect()
        let count = try await fixture.count("localized_select"); XCTAssertEqual(count, 2)
    }
    func testSMTPDropAfterDataIsUnknownWithoutRetry() async throws {
        let fixture=try await Fixture(mode:"smtp",scenario:"data-drop");defer { fixture.close() }
        do { try await SMTPService(config:fixture.config,password:"synthetic").send(from:"qa@example.invalid",fromName:nil,recipients:["peer@example.invalid"],message:"Subject: Fixture\r\n\r\nbody");XCTFail("Must retain unknown outcome") }
        catch { XCTAssertEqual(error as? MailFailure,.unknownSubmission) }
        let count=try await fixture.count("data");XCTAssertEqual(count,1)
    }
    func testUnexpectedPositiveReplyAfterDataIsUnknown() async throws {
        let fixture = try await Fixture(mode: "smtp", scenario: "data-weird"); defer { fixture.close() }
        do { try await SMTPService(config: fixture.config, password: "synthetic").send(from: "qa@example.invalid", fromName: nil, recipients: ["peer@example.invalid"], message: "Subject: Fixture\r\n\r\nbody"); XCTFail("Unexpected reply cannot authorize retry") }
        catch { XCTAssertEqual(error as? MailFailure, .unknownSubmission) }
    }
    func testSMTPDataRejectionIsKnown() async throws {
        let fixture=try await Fixture(mode:"smtp",scenario:"data-reject");defer { fixture.close() }
        do { try await SMTPService(config:fixture.config,password:"synthetic").send(from:"qa@example.invalid",fromName:nil,recipients:["peer@example.invalid"],message:"Subject: Fixture\r\n\r\nbody");XCTFail("Must reject") }
        catch { XCTAssertEqual(error as? MailFailure,.serverRejected) }
    }
    func testIMAPListSelectFetchBodySearchAndFlags() async throws {
        let fixture=try await Fixture(mode:"imap",scenario:"accept");defer { fixture.close() }
        let service=IMAPService(config:fixture.config,password:"synthetic")
        try await service.connectAndLogin()
        let boxes=try await service.listMailboxes();XCTAssertEqual(boxes.map(\.kind),[.inbox,.sent])
        let rows=try await service.fetchRecent(mailbox:"INBOX",limit:50)
        XCTAssertEqual(service.selectedUIDValidity,97);XCTAssertEqual(rows.first?.uid,11)
        let body=try await service.fetchMessageData(mailbox:"INBOX",uid:11,byteLimit:nil)
        XCTAssertEqual(MIME.parse(body).text,"Mail fixture body")
        let search=try await service.searchText(mailbox:"INBOX",query:"Fixture",limit:50);XCTAssertEqual(search.first?.uid,11)
        try await service.store(mailbox:"INBOX",uid:11,.flagged,add:true)
        try await service.move(uid:11,from:"INBOX",to:"Sent")
        await service.disconnect()
    }
    func testIMAPAppendLossIsNotReplayed() async throws {
        let fixture=try await Fixture(mode:"imap",scenario:"append-drop");defer { fixture.close() }
        let service=IMAPService(config:fixture.config,password:"synthetic");try await service.connectAndLogin()
        do { try await service.append(mailbox:"Sent",rawMessage:"Subject: Fixture\r\n\r\nbody",seen:true,draft:false);XCTFail("Missing acknowledgement") } catch {}
        await service.disconnect()
        let count=try await fixture.count("append");XCTAssertEqual(count,1)
    }
    func testSMTPTLSUsesCertificateVerification() async throws {
        let fixture=try await Fixture(mode:"smtp",scenario:"tls");defer { fixture.close() }
        var config=fixture.config;config.smtpSecurity = .tls
        try await SMTPService(config:config,password:"synthetic",tlsCAFile:fixture.root.appendingPathComponent("cert.pem").path).send(from:"qa@example.invalid",fromName:nil,recipients:["peer@example.invalid"],message:"Subject: Fixture\r\n\r\nbody")
        let count=try await fixture.count("data");XCTAssertEqual(count,1)
    }
    func testUntrustedCertificateFailsClosed() async throws {
        let fixture=try await Fixture(mode:"imap",scenario:"tls");defer { fixture.close() }
        var config=fixture.config;config.imapSecurity = .tls
        let service=IMAPService(config:config,password:"synthetic")
        do { try await service.connectAndLogin();XCTFail("Untrusted certificate must fail") } catch {}
        await service.disconnect()
    }
    func testIMAPStartTLS() async throws {
        let fixture=try await Fixture(mode:"imap",scenario:"starttls");defer { fixture.close() }
        var config=fixture.config;config.imapSecurity = .startTLS
        let service=IMAPService(config:config,password:"synthetic",tlsCAFile:fixture.root.appendingPathComponent("cert.pem").path)
        try await service.connectAndLogin();let boxes=try await service.listMailboxes();XCTAssertEqual(boxes.count,2)
        await service.disconnect()
    }
}
final class Fixture: @unchecked Sendable {
    let root:URL
    let process:Process
    let config:MailAccountConfig
    init(mode:String,scenario:String) async throws {
        root=FileManager.default.temporaryDirectory.appendingPathComponent("makosh-mail-fixture-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        if (scenario == "tls" || scenario.contains("starttls")) {
            let openssl=Process();openssl.executableURL=URL(fileURLWithPath:"/usr/bin/openssl")
            openssl.arguments=["req","-x509","-newkey","rsa:2048","-nodes","-days","1","-subj","/CN=localhost","-addext","subjectAltName=DNS:localhost","-addext","subjectKeyIdentifier=hash","-addext","authorityKeyIdentifier=keyid:always","-addext","basicConstraints=critical,CA:TRUE","-keyout",root.appendingPathComponent("key.pem").path,"-out",root.appendingPathComponent("cert.pem").path]
            openssl.standardOutput=FileHandle.nullDevice;openssl.standardError=FileHandle.nullDevice
            try openssl.run();openssl.waitUntilExit();guard openssl.terminationStatus==0 else { throw MailFailure.storage }
        }
        let script=URL(fileURLWithPath:#filePath).deletingLastPathComponent().appendingPathComponent(scenario == "monitor-starttls" ? "Fixtures/idle_worker_server.py" : "Fixtures/protocol_server.py")
        process=Process();process.executableURL=URL(fileURLWithPath:"/usr/bin/python3");process.arguments=[script.path,mode,scenario,root.path]
        process.standardOutput=FileHandle.nullDevice;process.standardError=FileHandle.nullDevice;try process.run()
        let portFile=root.appendingPathComponent("port")
        for _ in 0..<300 { if FileManager.default.fileExists(atPath:portFile.path) { break };try await Task.sleep(for:.milliseconds(10)) }
        let port=try XCTUnwrap(Int(String(contentsOf:portFile,encoding:.utf8)))
        config=MailAccountConfig(id:UUID().uuidString,displayName:"QA",email:"qa@example.invalid",imapHost:"localhost",imapPort:port,imapSecurity:.none,imapUsername:"qa@example.invalid",smtpHost:"localhost",smtpPort:port,smtpSecurity:.none,smtpUsername:"qa@example.invalid")
    }
    func count(_ key:String) async throws -> Int {
        let url=root.appendingPathComponent("result.json")
        for _ in 0..<300 { if FileManager.default.fileExists(atPath:url.path) { break };try await Task.sleep(for:.milliseconds(10)) }
        let result=try JSONSerialization.jsonObject(with:Data(contentsOf:url)) as? [String:Any]
        return try XCTUnwrap(result?[key] as? Int)
    }
    func close() { if process.isRunning { process.terminate() };try? FileManager.default.removeItem(at:root) }
}
