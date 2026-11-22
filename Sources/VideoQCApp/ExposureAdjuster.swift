import Cocoa
import CoreImage
import Metal
import VideoQCLib

/// @MainActor Metal-accelerated exposure adjuster matching After Effects EV exposure math (I * 2^EV).
@MainActor
public final class ExposureAdjuster {
    public static let shared = ExposureAdjuster()
    
    private let ciContext: CIContext
    
    public init() {
        if let device = MTLCreateSystemDefaultDevice() {
            self.ciContext = CIContext(mtlDevice: device, options: [.useSoftwareRenderer: false])
        } else {
            self.ciContext = CIContext(options: [.useSoftwareRenderer: false])
        }
    }
    
    /// Applies the LUT, then the exposure (in EV stops), as the video composition does during playback.
    /// Fast execution (~3ms on 1080p). Returns the original image if there is nothing to apply.
    /// `gamma` > 0: the viewer gamma too (stills shown in the viewport only, never screenshots or checks).
    func applyLook(to cgImage: CGImage, ev: Double, lut: CubeLUT?, gamma: Double = 0) -> CGImage {
        guard abs(ev) >= 0.001 || lut != nil || gamma > 0 else { return cgImage }
        var image = CIImage(cgImage: cgImage)
        if let lut { image = image.applyingLUT(lut) }
        if abs(ev) >= 0.001 { image = image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: ev]) }
        if gamma > 0 { image = image.applyingDisplayGamma(gamma, source: cgImage.colorSpace) }
        return ciContext.createCGImage(image, from: image.extent) ?? cgImage
    }
}
