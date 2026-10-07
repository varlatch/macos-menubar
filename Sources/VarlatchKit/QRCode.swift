import CoreImage
import Foundation

/// A QR code of a device sign-in's address, for a phone's camera. The code
/// is typed in by hand, so only the address goes in.
public enum QRCode {
    /// Black modules on white, one pixel per module and no quiet zone: the
    /// view scales it without smoothing and puts it on white.
    public static func image(for text: String) -> CGImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        return CIContext(options: [.useSoftwareRenderer: false]).createCGImage(output, from: output.extent)
    }
}
