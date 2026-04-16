import AVFoundation
import Combine
import Vision
import UIKit

// MARK: - TireOCRProcessor
// This class receives video frames from the camera and runs Apple's
// Vision OCR on each frame to detect text. When text is found, it passes
// the raw strings to TireTextParser to extract tire specifications.
//
// It runs on a background thread so the camera preview stays smooth.

class TireOCRProcessor: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {

    // Published properties that the SwiftUI views observe
    @Published var recognizedTexts: [RecognizedText] = []  // All detected text with positions
    @Published var detectedSpec: TireSpec?                  // Parsed tire spec (nil if not yet found)
    @Published var scanState: ScanState = .scanning

    // The parser that extracts tire info from raw text
    private let parser = TireTextParser()

    // Throttle OCR to ~5 frames per second (no need to process every frame)
    private var lastProcessTime: Date = .distantPast
    private let processInterval: TimeInterval = 0.2  // 200ms between OCR runs

    // MARK: - Frame Processing
    // This method is called automatically for every camera frame.
    // AVFoundation calls it on the background queue we specified in CameraManager.

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // Throttle: skip frames if we processed one recently
        let now = Date()
        guard now.timeIntervalSince(lastProcessTime) >= processInterval else { return }
        lastProcessTime = now

        // Get the pixel buffer (image data) from the frame
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // Create a Vision OCR request
        let request = VNRecognizeTextRequest { [weak self] request, error in
            guard let self = self else { return }

            if let error = error {
                DispatchQueue.main.async {
                    self.scanState = .error("OCR Error: \(error.localizedDescription)")
                }
                return
            }

            // Extract the recognized text observations
            guard let observations = request.results as? [VNRecognizedTextObservation] else { return }

            // Convert observations to our RecognizedText model
            var texts: [RecognizedText] = []
            var allRawText = ""

            for observation in observations {
                // Get the top candidate (most likely reading)
                guard let candidate = observation.topCandidates(1).first else { continue }

                let text = RecognizedText(
                    text: candidate.string,
                    confidence: candidate.confidence,
                    boundingBox: observation.boundingBox  // Normalized coordinates (0-1)
                )
                texts.append(text)
                allRawText += candidate.string + " "
            }

            // Try to parse tire specs from all detected text
            let spec = self.parser.parse(allRawText)

            // Update UI on main thread
            DispatchQueue.main.async {
                self.recognizedTexts = texts
                if let spec = spec {
                    self.detectedSpec = spec
                    self.scanState = .detected
                }
            }
        }

        // Configure the OCR request
        request.recognitionLevel = .accurate     // More accurate but slightly slower
        request.recognitionLanguages = ["en-US", "fr-FR"]  // English + French
        request.usesLanguageCorrection = false   // Don't "correct" tire codes!

        // Run the request
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        try? handler.perform([request])
    }

    // MARK: - Actions

    /// User confirmed the detected scan
    func confirmScan() {
        scanState = .captured
    }

    /// Reset to start scanning again
    func resetScan() {
        detectedSpec = nil
        recognizedTexts = []
        scanState = .scanning
    }
}

// MARK: - RecognizedText
// Represents a piece of text detected by OCR, with its position on screen

struct RecognizedText: Identifiable {
    let id = UUID()
    let text: String
    let confidence: Float     // 0.0 to 1.0
    let boundingBox: CGRect   // Position in normalized coordinates (0-1 range)

    // Check if this text looks like a tire size pattern
    var isTireSize: Bool {
        let pattern = #"\d{3}\s*/\s*\d{2}\s*R\s*\d{2}"#
        return text.range(of: pattern, options: .regularExpression) != nil
    }
}
