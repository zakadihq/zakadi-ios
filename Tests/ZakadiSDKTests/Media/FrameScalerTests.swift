import CoreVideo
import XCTest

@_spi(Testing) @testable import ZakadiSDK

/// Rung scaling of spec 07 7.29: 480x640 capture to rungs 3 and 4.
final class FrameScalerTests: XCTestCase {
    private let rungSizes = [(336, 448), (288, 384)]

    func testPixelTransferIsTheMethodFromIOS16() {
        if #available(iOS 16, *) {
            XCTAssertEqual(FrameScaler.defaultMethod, .pixelTransfer)
        } else {
            XCTAssertEqual(FrameScaler.defaultMethod, .coreImage)
        }
    }

    func testBothMethodsScaleToRungsThreeAndFour() throws {
        let source = try MediaFixtures.frame(width: 480, height: 640) { _ in 120 }
        for method in [FrameScaler.Method.pixelTransfer, .coreImage] {
            let scaler = FrameScaler(method: method)
            for (width, height) in rungSizes {
                let scaled = try scaler.scale(source, width: width, height: height)
                XCTAssertEqual(CVPixelBufferGetWidth(scaled), width, "\(method)")
                XCTAssertEqual(CVPixelBufferGetHeight(scaled), height, "\(method)")
                XCTAssertEqual(
                    CVPixelBufferGetPixelFormatType(scaled), CaptureSettings.pixelFormat)
                let centre = MediaFixtures.luma(scaled, column: width / 2, row: height / 2)
                XCTAssertEqual(Int(centre), 120, accuracy: 4, "\(method) \(width)x\(height)")
            }
        }
    }

    func testASourceWiderThan3x4IsCroppedAboutItsCentre() throws {
        let source = try MediaFixtures.frame(width: 640, height: 640) { column in
            column < 80 || column >= 560 ? 16 : 200
        }
        for method in [FrameScaler.Method.pixelTransfer, .coreImage] {
            let scaled = try FrameScaler(method: method).scale(source, width: 336, height: 448)
            for column in [2, 168, 333] {
                let value = MediaFixtures.luma(scaled, column: column, row: 224)
                XCTAssertEqual(Int(value), 200, accuracy: 8, "\(method) column \(column)")
            }
        }
    }

    func testTheCropKeepsTheLargestCentred3x4Rectangle() {
        XCTAssertEqual(
            FrameScaler.centreCrop(width: 640, height: 640, aspect: 0.75),
            CGRect(x: 80, y: 0, width: 480, height: 640))
        XCTAssertEqual(
            FrameScaler.centreCrop(width: 720, height: 1280, aspect: 0.75),
            CGRect(x: 0, y: 160, width: 720, height: 960))
        XCTAssertEqual(
            FrameScaler.centreCrop(width: 480, height: 640, aspect: 0.75),
            CGRect(x: 0, y: 0, width: 480, height: 640))
    }
}
