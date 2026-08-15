import Foundation
import RuneScribeRuntimeCore
import XCTest

final class RuntimeIntegrityDigestTests: XCTestCase {
    func testSHA256HexUsesCanonicalLowercaseEncoding() {
        XCTAssertEqual(
            RuntimeIntegrityDigest.sha256Hex(Data()),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
        XCTAssertEqual(
            RuntimeIntegrityDigest.sha256Hex(Data("abc".utf8)),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }
}
