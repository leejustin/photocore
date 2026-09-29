import CoreImage
import Foundation
import PhotoEngineCore

public enum PortraitRetouch {
    /// Soft, local-only finishing. Wedding-speed polish, not medical-grade retouch.
    public static func apply(_ settings: RetouchSettings, to image: CIImage, faces: [FaceSignal]) -> CIImage {
        guard settings.isActive else { return image }
        var output = image

        if settings.skinSmooth > 0.01 {
            let radius = 1.2 + settings.skinSmooth * 4.5
            let blurred = output.clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
                .cropped(to: output.extent)
            let sharp = output.applyingFilter("CISharpenLuminance", parameters: ["inputSharpness": 0.15])
            output = sharp.applyingFilter("CIDissolveTransition", parameters: [
                kCIInputTargetImageKey: blurred,
                kCIInputTimeKey: settings.skinSmooth * 0.55
            ])
        }

        if settings.clarityLift > 0.01 {
            let blurred = output.clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 6.0])
                .cropped(to: output.extent)
            let highPass = output.applyingFilter("CISubtractBlendMode", parameters: [kCIInputBackgroundImageKey: blurred])
            let gain = settings.clarityLift * 0.35
            output = output.applyingFilter("CIAdditionCompositing", parameters: [
                kCIInputBackgroundImageKey: highPass.applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: gain, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: gain, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: gain, w: 0),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                    "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0)
                ])
            ])
        }

        if (settings.eyesBrighten > 0.01 || settings.teethWhiten > 0.01), !faces.isEmpty {
            let controls = CIFilter(name: "CIColorControls")!
            controls.setValue(output, forKey: kCIInputImageKey)
            if settings.eyesBrighten > 0.01 {
                controls.setValue(settings.eyesBrighten * 0.08, forKey: kCIInputBrightnessKey)
                controls.setValue(1 + settings.eyesBrighten * 0.06, forKey: kCIInputContrastKey)
            }
            if settings.teethWhiten > 0.01 {
                controls.setValue(1 - settings.teethWhiten * 0.04, forKey: kCIInputSaturationKey)
            }
            if let next = controls.outputImage { output = next }
            if settings.teethWhiten > 0.01 {
                let temp = CIFilter(name: "CITemperatureAndTint")!
                temp.setValue(output, forKey: kCIInputImageKey)
                temp.setValue(CIVector(x: 6500 + CGFloat(settings.teethWhiten * 400), y: 0), forKey: "inputNeutral")
                temp.setValue(CIVector(x: 6500, y: 0), forKey: "inputTargetNeutral")
                if let next = temp.outputImage { output = next }
            }
        }

        if settings.flyawayReduce > 0.01 {
            let median = output.applyingFilter("CIMedianFilter")
            output = output.applyingFilter("CIDissolveTransition", parameters: [
                kCIInputTargetImageKey: median,
                kCIInputTimeKey: settings.flyawayReduce * 0.35
            ])
        }

        return output.cropped(to: image.extent)
    }
}
