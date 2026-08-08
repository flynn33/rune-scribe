import XCTest
import CryptoKit
import Metal
@testable import RuneScrib

final class CompatibilityBaselineTests: XCTestCase {
    private static let bundledFontSHA256 = Data([
        0x61, 0x5b, 0x6c, 0x11, 0x66, 0xa8, 0xc5, 0x18,
        0x16, 0xdc, 0x15, 0x36, 0x78, 0x4a, 0xcb, 0xf4,
        0x86, 0x54, 0x7e, 0x3b, 0xed, 0x03, 0xdb, 0xfd,
        0xd7, 0x09, 0x10, 0xe1, 0x00, 0x66, 0x79, 0x3b,
    ])

    func testBundledFontMatchesFixedSHA256() throws {
        let fontURL = try XCTUnwrap(
            Bundle(for: CompatibilityBaselineTests.self)
                .url(forResource: "NotoSansRunic-Regular", withExtension: "ttf")
                ?? Bundle.main.url(forResource: "NotoSansRunic-Regular", withExtension: "ttf")
        )
        let digest = Data(SHA256.hash(data: try Data(contentsOf: fontURL)))

        XCTAssertEqual(digest, Self.bundledFontSHA256)
    }

    func testSplashAndMetalLibraryRemainHostResources() throws {
        let testBundle = Bundle(for: CompatibilityBaselineTests.self)
        let splashURL = try XCTUnwrap(
            testBundle.url(
                forResource: "raven-forge-spp-splash",
                withExtension: "mp4"
            ) ?? Bundle.main.url(
                forResource: "raven-forge-spp-splash",
                withExtension: "mp4"
            )
        )
        XCTAssertGreaterThan(try Data(contentsOf: splashURL).count, 0)

        let libraryURL = try XCTUnwrap(
            testBundle.url(forResource: "default", withExtension: "metallib")
                ?? Bundle.main.url(forResource: "default", withExtension: "metallib")
        )
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let library = try device.makeLibrary(URL: libraryURL)
        XCTAssertNotNil(library.makeFunction(name: "vertex_fullscreen"))
        XCTAssertNotNil(library.makeFunction(name: "fragment_rune_background"))
    }

}
