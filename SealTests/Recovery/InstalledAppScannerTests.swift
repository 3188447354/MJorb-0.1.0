import Foundation
import Testing
import UIKit
@testable import Seal

struct InstalledAppScannerTests {
    @Test
    func decodesLaunchServicesBGRAIconWithPaddedRows() throws {
        let width = 16
        let bytesPerRow = (width + 1) * MemoryLayout<UInt32>.size
        let header = Data(repeating: 0, count: 32)
        let pixels = Data(repeating: 0xFF, count: width * bytesPerRow)

        let pngData = try #require(
            InstalledAppScanner.decodeLaunchServicesIconData(header + pixels)
        )
        let image = try #require(UIImage(data: pngData))

        #expect(image.size.width == CGFloat(width))
        #expect(image.size.height == CGFloat(width))
    }

    @Test
    func acceptsImageDataReturnedByLaunchServices() throws {
        let pngData = try #require(
            Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a3ioAAAAASUVORK5CYII=")
        )

        let decoded = try #require(InstalledAppScanner.decodeLaunchServicesIconData(pngData))

        #expect(UIImage(data: decoded) != nil)
    }
}
