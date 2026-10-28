import Foundation
import XCTest
@testable import ZIPFoundation

final class SealZIPCompatibilityTests: XCTestCase {
    private func archive(_ value: String) throws -> Archive {
        try Archive(data: XCTUnwrap(Data(base64Encoded: value)), accessMode: .read)
    }

    func testZIP64EmptyDirectoryWithRegularMode() throws {
        let entry = try XCTUnwrap(archive("UEsDBC0ACAgAAAAAAAAAAAAA//////////8aABQAUGF5bG9hZC9FeGFtcGxlLmFwcC9XYXRjaC8BABAAAAAAAAAAAAAAAAAAAAAAAFBLBwgAAAAAAAAAAAAAAAAAAAAAAAAAAFBLAQItAy0ACAgAAAAAAAAAAAAA//////////8aABQAAAAAAAAAAADtgQAAAABQYXlsb2FkL0V4YW1wbGUuYXBwL1dhdGNoLwEAEAAAAAAAAAAAAAAAAAAAAAAAUEsFBgAAAAABAAEAXAAAAGQAAAAAAA==").first(where: { _ in true }))
        XCTAssertEqual(entry.type, .directory)
        XCTAssertEqual(entry.uncompressedSize, 0)
        XCTAssertEqual(entry.compressedSize, 0)
        XCTAssertEqual(entry.checksum, 0)
    }

    func testNonemptyTrailingSlashIsNotDiscardedAsDirectory() throws {
        let entry = try XCTUnwrap(archive("UEsDBBQAAAAAAAAAIQBj8/OtBAAAAAQAAAAaAAAAUGF5bG9hZC9FeGFtcGxlLmFwcC9XYXRjaC9kYXRhUEsBAhQDFAAAAAAAAAAhAGPz860EAAAABAAAABoAAAAAAAAAAAAAAO2BAAAAAFBheWxvYWQvRXhhbXBsZS5hcHAvV2F0Y2gvUEsFBgAAAAABAAEASAAAADwAAAAAAA==").first(where: { _ in true }))
        XCTAssertEqual(entry.type, .file)
        XCTAssertEqual(entry.uncompressedSize, 4)
    }

    func testCorruptedDataStillFailsCRC() throws {
        let manager = FileManager.default
        let dir = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: dir) }
        let source = dir.appendingPathComponent("bad.zip")
        try XCTUnwrap(Data(base64Encoded: "UEsDBBQAAAAAAER3XF2lIBfbBAAAAAQAAAAYAAAAUGF5bG9hZC9FeGFtcGxlLmFwcC9kYXRhQEJDRFBLAQIUAxQAAAAAAER3XF2lIBfbBAAAAAQAAAAYAAAAAAAAAAAAAACAAQAAAABQYXlsb2FkL0V4YW1wbGUuYXBwL2RhdGFQSwUGAAAAAAEAAQBGAAAAOgAAAAAA")).write(to: source)
        XCTAssertThrowsError(try manager.unzipItem(at: source, to: dir.appendingPathComponent("out"))) { error in
            guard case Archive.ArchiveError.invalidCRC32 = error else {
                return XCTFail("Expected CRC failure, got: \(error)")
            }
        }
    }
}
