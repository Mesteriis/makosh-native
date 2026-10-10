import Foundation
import XCTest
import EncryptionProvider
import OpenSSLEncryption

final class TelegramCryptoTests: XCTestCase {
    func testModularExponentiationKnownVector() {
        // Textbook RSA arithmetic: 65^17 mod 3233 = 2790 (0x0AE6).
        // Exercises the genuine Objective-C provider and linked OpenSSL BN API.
        let context = OpenSSLEncryptionProvider().createBignumContext()
        let base = context.create()
        let exponent = context.create()
        let modulus = context.create()
        let result = context.create()
        context.assignWord(to: base, value: 65)
        context.assignWord(to: exponent, value: 17)
        context.assignWord(to: modulus, value: 3233)
        XCTAssertTrue(context.modExp(into: result, a: base, b: exponent, mod: modulus))
        XCTAssertEqual(context.getBin(result), Data([0x0a, 0xe6]))
    }

    func testBigEndianBinaryRoundTripAndCloneIsolation() {
        let context = OpenSSLEncryptionProvider().createBignumContext()
        let number = context.create()
        // Larger than a machine word, with internal zero and high-bit bytes.
        let bytes = Data([0x80, 0x00, 0xff, 0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0, 0x01])
        context.assignBin(to: number, value: bytes)
        XCTAssertEqual(context.getBin(number), bytes)
        let clone = context.clone(number)
        context.assignWord(to: number, value: 1)
        XCTAssertEqual(context.getBin(number), Data([1]))
        XCTAssertEqual(context.getBin(clone), bytes)
    }
}
