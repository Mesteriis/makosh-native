import Foundation
import XCTest

@testable import MakoshOSINT

/// The enrichers Makosh knows are exactly the ones flowsint v1.2.13 offers for people and organizations.
final class OSINTEnricherCatalogueTests: XCTestCase {
    static let server: Set<String> = [
        "email_to_gravatar", "email_to_device_hudsonrock", "email_to_breaches", "email_to_username", "email_to_domain",
        "email_to_intelligence", "email_to_domains", "phone_to_carrier", "phone_to_device_hudsonrock", "username_to_socials_maigret",
        "username_to_socials_sherlock", "username_to_device_hudsonrock", "username_to_dehashed", "individual_to_domains", "org_to_domains",
        "org_to_asn", "domain_to_dns", "domain_to_whois", "domain_to_subdomains",
    ]

    func testCatalogueMatchesServerNames() {
        XCTAssertEqual(Set(OSINTEnricher.allCases.map(\.rawValue)), Self.server)
        XCTAssertEqual(Set(OSINTEnricher.knownKeys), Set(OSINTEnricher.allCases.compactMap(\.requiredKey)))
        XCTAssertEqual(
            Set(OSINTEnricher.knownKeys), ["HIBP_API_KEY", "VERIPHONE_API_KEY", "WHOXY_API_KEY", "DEHASHED_API_KEY", "PDCP_API_KEY"])
    }

    func testEveryKeyHasAnInstruction() {
        for key in OSINTEnricher.knownKeys {
            let instruction = OSINTKeyInstruction.instruction(for: key)
            XCTAssertNotNil(instruction, key)
            XCTAssertEqual(instruction?.url.scheme, "https", key)
            XCTAssertFalse(instruction?.steps.isEmpty ?? true, key)
        }
        XCTAssertNil(OSINTKeyInstruction.instruction(for: "NO_SUCH_KEY"))
    }

    func testDefaultsAndSpeed() {
        XCTAssertTrue(OSINTEnricher.automaticDefault.allSatisfy { $0.requiredKey == nil && !$0.isSlow })
        XCTAssertTrue(OSINTEnricher.manualDefault.allSatisfy { $0.requiredKey == nil })
        XCTAssertTrue(OSINTEnricher.usernameToSherlock.isSlow)
        XCTAssertTrue(OSINTEnricher.domainToSubdomains.isSlow)
        XCTAssertEqual(OSINTEnricher.domainToWhois.inputType, .domain)
        XCTAssertEqual(OSINTEnricher.orgToASN.outputTypes, [.asn])
        XCTAssertEqual(OSINTEnricher.emailToDehashed.outputTypes, [.individual])
    }
}
