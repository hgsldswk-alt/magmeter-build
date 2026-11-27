import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

enum DownloadCode {
    static func url(appID: String?) -> String? {
        guard let appID, !appID.isEmpty, appID.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return "https://apps.apple.com/app/id" + appID
    }

    static func image(for url: String, size: Int = 264) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.utf8)
        filter.correctionLevel = "M"
        guard let code = filter.outputImage else { return nil }
        let extent = code.extent.insetBy(dx: -4, dy: -4)
        let withQuietZone = code.composited(over: CIImage(color: .white).cropped(to: extent))
        let factor = max(1, floor(CGFloat(size) / extent.width))
        let enlarged = withQuietZone.transformed(by: CGAffineTransform(scaleX: factor, y: factor))
        return CIContext().createCGImage(enlarged, from: enlarged.extent)
    }
}
