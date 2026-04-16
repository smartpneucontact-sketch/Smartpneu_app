import Combine
import UIKit
import Vision
import CoreImage
import CoreImage.CIFilterBuiltins

// MARK: - BackgroundRemover
// Removes background from tire photos, isolates the tire only (ignoring stand/rack),
// crops to square, centers, and enhances brightness so tread detail is visible.
//
// Pipeline: Original → Square crop → Instance segmentation (largest = tire) →
//           Soft mask → Brightness boost → Center in square → Composite on background

class BackgroundRemover: ObservableObject {

    @Published var isProcessing = false
    @Published var processedImage: UIImage?
    @Published var error: String?

    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    // MARK: - Background Colors

    enum BackgroundStyle {
        case white
        case lightGray
        case transparent
        case custom(UIColor)
    }

    // MARK: - Standard Output Size
    /// All processed images are resized to this fixed square dimension (pixels).
    /// Ensures consistent output regardless of camera resolution or photo mode.
    static let standardOutputSize: CGFloat = 2048

    // MARK: - Edge Quality

    enum EdgeQuality: String, CaseIterable {
        case erodeFeather = "Éroder + Lisser"       // Shrink mask 2px then feather — removes fringe
        case softBlur = "Flou doux"                  // Larger Gaussian blur — smooth transitions
        case closeFill = "Remplir + Lisser"          // Morphological close + erode + feather — preserves tread grooves
    }

    // MARK: - Main Pipeline

    func removeBackground(
        from image: UIImage,
        backgroundStyle: BackgroundStyle = .white,
        edgeQuality: EdgeQuality = .erodeFeather,
        photoMode: PhotoMode = .side,
        completion: @escaping (UIImage?) -> Void
    ) {
        DispatchQueue.main.async { self.isProcessing = true }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            // Step 0: Normalize orientation — bake the UIImage orientation into pixels
            // so CGImage/CIImage don't lose it (fixes 90° rotation from library photos)
            let normalizedImage = self.normalizeOrientation(image)

            // Step 1: Crop based on mode
            // Side = square (1:1), Front 2 = portrait (3:4), Front 4 = tall portrait (3:8)
            let croppedImage: UIImage
            switch photoMode {
            case .side:
                croppedImage = self.cropToSquare(normalizedImage)
            case .front:
                croppedImage = self.cropToPortrait(normalizedImage, ratio: 3.0 / 4.0)
            case .front4:
                croppedImage = self.cropToPortrait(normalizedImage, ratio: 3.0 / 8.0)
            }

            guard let cgImage = croppedImage.cgImage else {
                self.finish(with: nil, error: "Image invalide", completion: completion)
                return
            }

            let originalCI = CIImage(cgImage: cgImage)
            let imageSize = originalCI.extent

            // Step 2: Run foreground instance mask — detects separate foreground objects
            let request = VNGenerateForegroundInstanceMaskRequest()
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

            do {
                try handler.perform([request])
            } catch {
                self.finish(with: nil, error: "Erreur Vision: \(error.localizedDescription)", completion: completion)
                return
            }

            guard let result = request.results?.first else {
                self.finish(with: nil, error: "Aucun sujet détecté", completion: completion)
                return
            }

            do {
                // Step 2b: Select instances based on photo mode
                // Side view: largest instance only (tire, ignore stand)
                // Front view: all large instances (multiple tires), ignore small debris
                let tireInstances: IndexSet
                if photoMode == .side {
                    tireInstances = try self.findLargestInstance(result: result, handler: handler)
                } else {
                    tireInstances = try self.findLargeInstances(result: result, handler: handler)
                }

                // Generate the mask for the selected instances
                let maskPixelBuffer = try result.generateScaledMaskForImage(
                    forInstances: tireInstances,
                    from: handler
                )

                let maskCI = CIImage(cvPixelBuffer: maskPixelBuffer)

                // Scale the mask to match the original image dimensions
                let scaleX = imageSize.width / maskCI.extent.width
                let scaleY = imageSize.height / maskCI.extent.height
                let scaledMask = maskCI.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

                // Refine mask edges based on chosen quality method
                let softMask = self.refineMask(scaledMask, method: edgeQuality, extent: imageSize)

                // Apply the mask: blend original over transparent background
                let blendFilter = CIFilter(name: "CIBlendWithMask")!
                blendFilter.setValue(originalCI, forKey: kCIInputImageKey)
                let transparentBG = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0))
                    .cropped(to: imageSize)
                blendFilter.setValue(transparentBG, forKey: kCIInputBackgroundImageKey)
                blendFilter.setValue(softMask, forKey: kCIInputMaskImageKey)

                guard let maskedOutput = blendFilter.outputImage else {
                    self.finish(with: nil, error: "Erreur composition masque", completion: completion)
                    return
                }

                // Step 3: Skip post-processing brightness boost — exposure is now user-controlled
                var subjectCIImage = maskedOutput

                // Step 4: Center subject in a fixed 2048×2048 canvas (standard output size)
                let outputSize = BackgroundRemover.standardOutputSize
                subjectCIImage = self.centerSubjectInCanvas(
                    subjectCIImage,
                    canvasWidth: outputSize,
                    canvasHeight: outputSize
                )

                // Step 5: Composite onto chosen background
                let finalImage: UIImage?

                switch backgroundStyle {
                case .transparent:
                    finalImage = self.ciImageToUIImage(subjectCIImage)
                case .white:
                    finalImage = self.compositeOnBackground(subject: subjectCIImage, backgroundColor: .white)
                case .lightGray:
                    finalImage = self.compositeOnBackground(subject: subjectCIImage, backgroundColor: UIColor(white: 0.95, alpha: 1.0))
                case .custom(let color):
                    finalImage = self.compositeOnBackground(subject: subjectCIImage, backgroundColor: color)
                }

                self.finish(with: finalImage, error: nil, completion: completion)

            } catch {
                self.finish(with: nil, error: "Erreur masque: \(error.localizedDescription)", completion: completion)
            }
        }
    }

    // MARK: - Step 1: Crop to Square

    /// Crops the image to a 1:1 square from the center
    private func cropToSquare(_ image: UIImage) -> UIImage {
        guard let cgImage = image.cgImage else { return image }

        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        let side = min(width, height)

        let originX = (width - side) / 2
        let originY = (height - side) / 2
        let cropRect = CGRect(x: originX, y: originY, width: side, height: side)

        guard let cropped = cgImage.cropping(to: cropRect) else { return image }
        return UIImage(cgImage: cropped, scale: image.scale, orientation: image.imageOrientation)
    }

    /// Crops the image to the given portrait ratio from the center (for front view of stacked tires)
    /// ratio = width/height, e.g. 3/4 for 2 tires, 3/8 for 4 tires
    private func cropToPortrait(_ image: UIImage, ratio: CGFloat = 3.0 / 4.0) -> UIImage {
        guard let cgImage = image.cgImage else { return image }

        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)

        // Target aspect ratio (width:height)
        let targetRatio: CGFloat = ratio
        let currentRatio = width / height

        let cropWidth: CGFloat
        let cropHeight: CGFloat

        if currentRatio > targetRatio {
            // Image is wider than 3:4 → crop width
            cropHeight = height
            cropWidth = height * targetRatio
        } else {
            // Image is taller than 3:4 → crop height
            cropWidth = width
            cropHeight = width / targetRatio
        }

        let originX = (width - cropWidth) / 2
        let originY = (height - cropHeight) / 2
        let cropRect = CGRect(x: originX, y: originY, width: cropWidth, height: cropHeight)

        guard let cropped = cgImage.cropping(to: cropRect) else { return image }
        return UIImage(cgImage: cropped, scale: image.scale, orientation: image.imageOrientation)
    }

    // MARK: - Step 2b: Find Largest Instance (the Tire)

    /// Iterates through detected foreground instances, measures each mask's pixel area,
    /// and returns the IndexSet containing only the largest one (the tire).
    /// Falls back to allInstances if only one is detected.
    private func findLargestInstance(
        result: VNInstanceMaskObservation,
        handler: VNImageRequestHandler
    ) throws -> IndexSet {
        let allInstances = result.allInstances

        // If there's only 1 instance, use it directly
        if allInstances.count <= 1 {
            return allInstances
        }

        // Measure each instance's pixel area to find the tire (largest object)
        var largestInstance: Int = allInstances.first ?? 0
        var largestArea: Int = 0

        for instance in allInstances {
            let singleSet = IndexSet(integer: instance)
            let maskBuffer = try result.generateScaledMaskForImage(
                forInstances: singleSet,
                from: handler
            )

            let area = countMaskPixels(maskBuffer)
            if area > largestArea {
                largestArea = area
                largestInstance = instance
            }
        }

        return IndexSet(integer: largestInstance)
    }

    /// For front view: finds instances that are tires (similar sizes) and excludes
    /// outliers like fabric, stands, or background objects.
    /// Strategy: sort by area, find the cluster of similarly-sized objects (tires ≈ same size),
    /// exclude anything much larger (fabric/background) or much smaller (debris).
    private func findLargeInstances(
        result: VNInstanceMaskObservation,
        handler: VNImageRequestHandler
    ) throws -> IndexSet {
        let allInstances = result.allInstances

        if allInstances.count <= 1 {
            return allInstances
        }

        // Measure each instance's area
        var instanceAreas: [(instance: Int, area: Int)] = []

        for instance in allInstances {
            let singleSet = IndexSet(integer: instance)
            let maskBuffer = try result.generateScaledMaskForImage(
                forInstances: singleSet,
                from: handler
            )
            let area = countMaskPixels(maskBuffer)
            instanceAreas.append((instance, area))
        }

        // Sort by area descending
        instanceAreas.sort { $0.area > $1.area }

        // Strategy: tires are similar in size. Find the best cluster of 2-4 objects
        // whose sizes are within 2.5x of each other. Start from the largest and
        // keep adding instances that are within range.
        //
        // If the largest object is the fabric (much bigger than tires), the second
        // largest will be a tire. We compare each candidate to the median of the
        // current group to decide.

        guard let largest = instanceAreas.first else { return allInstances }

        // If only 2 instances, check if they're similar size. If one is >3x the other,
        // the smaller one is likely the tire(s) group — but actually in that case
        // the fabric might be one instance and tires another. Keep the largest that
        // looks like tires.
        if instanceAreas.count == 2 {
            let ratio = Double(instanceAreas[0].area) / max(Double(instanceAreas[1].area), 1.0)
            if ratio > 3.0 {
                // Huge difference — the larger one is probably fabric/background.
                // Keep the smaller one (the tires).
                return IndexSet(integer: instanceAreas[1].instance)
            } else {
                // Similar size — both are tires
                return IndexSet(instanceAreas.map(\.instance))
            }
        }

        // For 3+ instances: build a cluster of similarly-sized objects
        var cluster: [(instance: Int, area: Int)] = [largest]

        for i in 1..<instanceAreas.count {
            let candidate = instanceAreas[i]
            // Compare to the median of the current cluster
            let clusterMedian = cluster.map(\.area).sorted()[cluster.count / 2]
            let ratio = Double(clusterMedian) / max(Double(candidate.area), 1.0)

            // Keep if within 3x of the cluster median (tires are roughly same size)
            if ratio < 3.0 && ratio > 0.33 {
                cluster.append(candidate)
            }
        }

        // If the cluster has only 1 item and it's much bigger than everything else,
        // it might be the fabric. Try building a cluster from the 2nd largest instead.
        if cluster.count == 1 && instanceAreas.count >= 2 {
            let secondRatio = Double(instanceAreas[0].area) / max(Double(instanceAreas[1].area), 1.0)
            if secondRatio > 2.5 {
                // Restart cluster from 2nd largest
                cluster = [instanceAreas[1]]
                for i in 2..<instanceAreas.count {
                    let candidate = instanceAreas[i]
                    let clusterMedian = cluster.map(\.area).sorted()[cluster.count / 2]
                    let ratio = Double(clusterMedian) / max(Double(candidate.area), 1.0)
                    if ratio < 3.0 && ratio > 0.33 {
                        cluster.append(candidate)
                    }
                }
            }
        }

        let kept = IndexSet(cluster.map(\.instance))
        return kept.isEmpty ? allInstances : kept
    }

    /// Counts non-zero pixels in a grayscale mask to estimate the area of an instance
    private func countMaskPixels(_ pixelBuffer: CVPixelBuffer) -> Int {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return 0 }
        let ptr = baseAddress.assumingMemoryBound(to: UInt8.self)

        var count = 0
        let step = 4  // sample every 4th pixel for speed

        for y in stride(from: 0, to: height, by: step) {
            for x in stride(from: 0, to: width, by: step) {
                let offset = y * bytesPerRow + x
                if ptr[offset] > 128 {  // mask value above threshold = foreground
                    count += 1
                }
            }
        }

        return count
    }

    // MARK: - Mask Edge Refinement

    /// Sharpens a grayscale mask by boosting contrast so edge pixels snap toward 0 or 1.
    /// Uses CIColorControls: brightness shifts the midpoint, contrast steepens the curve.
    /// The result is a tighter, more binary edge with less gray fringe.
    private func sharpenMask(_ mask: CIImage, contrast: Float = 3.0, brightness: Float = -0.05, extent: CGRect) -> CIImage {
        guard let filter = CIFilter(name: "CIColorControls") else { return mask }
        filter.setValue(mask, forKey: kCIInputImageKey)
        filter.setValue(contrast, forKey: kCIInputContrastKey)
        filter.setValue(brightness, forKey: kCIInputBrightnessKey)
        filter.setValue(1.0, forKey: kCIInputSaturationKey)
        guard let output = filter.outputImage else { return mask }

        // Clamp back to 0–1 range (contrast can overshoot)
        guard let clamp = CIFilter(name: "CIColorClamp") else { return output.cropped(to: extent) }
        clamp.setValue(output, forKey: kCIInputImageKey)
        clamp.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputMinComponents")
        clamp.setValue(CIVector(x: 1, y: 1, z: 1, w: 1), forKey: "inputMaxComponents")
        return (clamp.outputImage ?? output).cropped(to: extent)
    }

    /// Applies one of three edge refinement strategies to the grayscale mask.
    private func refineMask(_ mask: CIImage, method: EdgeQuality, extent: CGRect) -> CIImage {
        switch method {

        case .erodeFeather:
            // 1) Erode: shrink mask by 4px to cut fringe/halo cleanly
            var refined = mask
            if let erode = CIFilter(name: "CIMorphologyMinimum") {
                erode.setValue(refined, forKey: kCIInputImageKey)
                erode.setValue(4.0, forKey: kCIInputRadiusKey)
                if let output = erode.outputImage {
                    refined = output.cropped(to: extent)
                }
            }
            // 2) Sharpen: push edge values toward 0/1 for a crisp boundary
            refined = sharpenMask(refined, contrast: 3.5, brightness: -0.05, extent: extent)
            // 3) Feather: tiny blur for a smooth anti-aliased edge
            if let blur = CIFilter(name: "CIGaussianBlur") {
                blur.setValue(refined, forKey: kCIInputImageKey)
                blur.setValue(1.5, forKey: kCIInputRadiusKey)
                if let output = blur.outputImage {
                    refined = output.cropped(to: extent)
                }
            }
            return refined

        case .softBlur:
            // 1) Erode to remove fringe
            var refined = mask
            if let erode = CIFilter(name: "CIMorphologyMinimum") {
                erode.setValue(refined, forKey: kCIInputImageKey)
                erode.setValue(3.0, forKey: kCIInputRadiusKey)
                if let output = erode.outputImage {
                    refined = output.cropped(to: extent)
                }
            }
            // 2) Sharpen mask edges
            refined = sharpenMask(refined, contrast: 2.5, brightness: -0.03, extent: extent)
            // 3) Larger blur for smooth, soft transitions
            if let blur = CIFilter(name: "CIGaussianBlur") {
                blur.setValue(refined, forKey: kCIInputImageKey)
                blur.setValue(3.5, forKey: kCIInputRadiusKey)
                if let output = blur.outputImage {
                    refined = output.cropped(to: extent)
                }
            }
            return refined

        case .closeFill:
            // 1) Morphological close: dilate then erode — fills small gaps in tread grooves
            var refined = mask
            // Dilate (expand white = grow mask)
            if let dilate = CIFilter(name: "CIMorphologyMaximum") {
                dilate.setValue(refined, forKey: kCIInputImageKey)
                dilate.setValue(3.0, forKey: kCIInputRadiusKey)
                if let output = dilate.outputImage {
                    refined = output.cropped(to: extent)
                }
            }
            // Erode back + extra trim (net: holes filled, edge trimmed 2px)
            if let erode = CIFilter(name: "CIMorphologyMinimum") {
                erode.setValue(refined, forKey: kCIInputImageKey)
                erode.setValue(5.0, forKey: kCIInputRadiusKey)
                if let output = erode.outputImage {
                    refined = output.cropped(to: extent)
                }
            }
            // 2) Sharpen for clean edges
            refined = sharpenMask(refined, contrast: 3.0, brightness: -0.04, extent: extent)
            // 3) Feather for smooth transition
            if let blur = CIFilter(name: "CIGaussianBlur") {
                blur.setValue(refined, forKey: kCIInputImageKey)
                blur.setValue(2.0, forKey: kCIInputRadiusKey)
                if let output = blur.outputImage {
                    refined = output.cropped(to: extent)
                }
            }
            return refined
        }
    }

    // MARK: - Step 4: Center Subject in Canvas

    /// Finds the non-transparent bounding box of the subject,
    /// then repositions it centered in the canvas with 6% padding.
    /// Works for both square (side) and portrait (front) canvases.
    private func centerSubjectInCanvas(_ image: CIImage, canvasWidth: CGFloat, canvasHeight: CGFloat) -> CIImage {
        let extent = image.extent

        // Render to find the tight bounding box of visible pixels
        guard let cgImage = ciContext.createCGImage(image, from: extent) else {
            return image
        }

        let subjectBounds = findSubjectBounds(cgImage)
        guard subjectBounds.width > 0 && subjectBounds.height > 0 else {
            return image
        }

        // 6% padding on each side → subject fills 88% of canvas
        let padding: CGFloat = 0.06
        let availableWidth = canvasWidth * (1.0 - padding * 2)
        let availableHeight = canvasHeight * (1.0 - padding * 2)

        // Scale to fit while maintaining aspect ratio
        let scaleX = availableWidth / subjectBounds.width
        let scaleY = availableHeight / subjectBounds.height
        let scale = min(scaleX, scaleY)

        // Crop to subject bounds
        let croppedSubject = image.cropped(to: CGRect(
            x: extent.origin.x + subjectBounds.origin.x,
            y: extent.origin.y + subjectBounds.origin.y,
            width: subjectBounds.width,
            height: subjectBounds.height
        ))

        // Reset origin to (0,0) then scale
        let translated = croppedSubject.transformed(by: CGAffineTransform(
            translationX: -(extent.origin.x + subjectBounds.origin.x),
            y: -(extent.origin.y + subjectBounds.origin.y)
        ))
        let scaled = translated.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        // Center in the canvas
        let scaledWidth = subjectBounds.width * scale
        let scaledHeight = subjectBounds.height * scale
        let offsetX = (canvasWidth - scaledWidth) / 2
        let offsetY = (canvasHeight - scaledHeight) / 2

        let centered = scaled.transformed(by: CGAffineTransform(translationX: offsetX, y: offsetY))

        // Force-crop to exact canvas dimensions
        return centered.cropped(to: CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight))
    }

    /// Scans pixel data to find the bounding box of non-transparent pixels
    private func findSubjectBounds(_ cgImage: CGImage) -> CGRect {
        let width = cgImage.width
        let height = cgImage.height

        guard let data = cgImage.dataProvider?.data,
              let ptr = CFDataGetBytePtr(data) else {
            return CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        }

        let bytesPerPixel = cgImage.bitsPerPixel / 8
        let bytesPerRow = cgImage.bytesPerRow

        var minX = width
        var minY = height
        var maxX = 0
        var maxY = 0

        let step = 4  // sample every 4th pixel for speed

        for y in stride(from: 0, to: height, by: step) {
            for x in stride(from: 0, to: width, by: step) {
                let offset = y * bytesPerRow + x * bytesPerPixel

                let alpha: UInt8
                if bytesPerPixel == 4 {
                    alpha = ptr[offset + 3]  // RGBA
                } else {
                    continue
                }

                if alpha > 20 {
                    minX = min(minX, x)
                    minY = min(minY, y)
                    maxX = max(maxX, x)
                    maxY = max(maxY, y)
                }
            }
        }

        guard maxX > minX && maxY > minY else {
            return CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        }

        // CGImage has origin at top-left, CIImage at bottom-left — convert Y
        let ciMinY = CGFloat(height - maxY)
        let ciMaxY = CGFloat(height - minY)

        return CGRect(
            x: CGFloat(minX),
            y: ciMinY,
            width: CGFloat(maxX - minX),
            height: ciMaxY - ciMinY
        )
    }

    // MARK: - Step 5: Composite on Background

    private func compositeOnBackground(
        subject: CIImage,
        backgroundColor: UIColor
    ) -> UIImage? {
        var red: CGFloat = 1, green: CGFloat = 1, blue: CGFloat = 1, alpha: CGFloat = 1
        backgroundColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha)

        let bgColor = CIImage(color: CIColor(red: red, green: green, blue: blue, alpha: alpha))
            .cropped(to: subject.extent)

        let composited = subject.composited(over: bgColor)
        return ciImageToUIImage(composited)
    }

    // MARK: - Helpers

    /// Re-draws the UIImage with orientation applied to actual pixel data.
    /// After this, .imageOrientation is always .up and cgImage matches what you see on screen.
    private func normalizeOrientation(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up else { return image }

        UIGraphicsBeginImageContextWithOptions(image.size, false, image.scale)
        image.draw(in: CGRect(origin: .zero, size: image.size))
        let normalized = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()

        return normalized ?? image
    }

    private func ciImageToUIImage(_ ciImage: CIImage) -> UIImage? {
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    private func finish(with image: UIImage?, error: String?, completion: @escaping (UIImage?) -> Void) {
        DispatchQueue.main.async {
            self.isProcessing = false
            self.processedImage = image
            self.error = error
            completion(image)
        }
    }

    // MARK: - Save / Export

    static func saveToPhotoLibrary(_ image: UIImage, completion: @escaping (Bool) -> Void) {
        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
        completion(true)
    }

    static func exportAsPNG(_ image: UIImage) -> Data? {
        return image.pngData()
    }

    static func exportAsJPEG(_ image: UIImage, quality: CGFloat = 0.9) -> Data? {
        return image.jpegData(compressionQuality: quality)
    }
}
