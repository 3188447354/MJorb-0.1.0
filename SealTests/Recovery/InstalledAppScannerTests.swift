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

    @Test @MainActor
    func acceptsImageDataReturnedByLaunchServices() throws {
        let size = CGSize(width: 1, height: 1)
        let pngData = try #require(
            UIGraphicsImageRenderer(size: size).image { context in
                UIColor.systemBlue.setFill()
                context.fill(CGRect(origin: .zero, size: size))
            }.pngData()
        )

        let decoded = try #require(InstalledAppScanner.decodeLaunchServicesIconData(pngData))

        #expect(UIImage(data: decoded) != nil)
    }
}
