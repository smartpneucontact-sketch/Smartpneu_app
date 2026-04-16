import AVFoundation
import Combine
import UIKit

// MARK: - CameraManager
// This class manages the camera hardware. It creates a capture session,
// configures the camera input, and provides a video output for both
// the live preview and frame-by-frame OCR processing.
//
// Think of it as the "plumbing" between the iPhone camera sensor and your app.

class CameraManager: NSObject, ObservableObject {

    // The capture session coordinates the flow of data from camera → output
    let captureSession = AVCaptureSession()

    // This output delivers individual video frames for OCR processing
    private let videoOutput = AVCaptureVideoDataOutput()

    // Queue for camera operations (must not block the main/UI thread)
    private let sessionQueue = DispatchQueue(label: "com.smartpneu.camera.session")

    // Delegate that will receive each video frame (our OCR processor)
    private var frameDelegate: AVCaptureVideoDataOutputSampleBufferDelegate?

    // Published property so SwiftUI knows when camera is ready
    @Published var isCameraReady = false
    @Published var cameraError: String?

    // MARK: - Setup

    /// Call this once to configure the camera. Pass in the delegate that will process frames.
    func configure(frameDelegate: AVCaptureVideoDataOutputSampleBufferDelegate) {
        self.frameDelegate = frameDelegate

        // Check camera permission first
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            setupSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                if granted {
                    self?.setupSession()
                } else {
                    DispatchQueue.main.async {
                        self?.cameraError = "Camera access denied. Go to Settings → SmartPneu → Camera to enable."
                    }
                }
            }
        default:
            DispatchQueue.main.async {
                self.cameraError = "Camera access denied. Go to Settings → SmartPneu → Camera to enable."
            }
        }
    }

    private func setupSession() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }

            self.captureSession.beginConfiguration()

            // Use high quality preset — iPhone Pro cameras handle this easily
            self.captureSession.sessionPreset = .high

            // MARK: Camera Input
            // Get the back camera (wide angle). On Pro models this is the 48MP sensor.
            guard let camera = AVCaptureDevice.default(
                .builtInWideAngleCamera,
                for: .video,
                position: .back
            ) else {
                DispatchQueue.main.async {
                    self.cameraError = "No back camera found"
                }
                return
            }

            do {
                let input = try AVCaptureDeviceInput(device: camera)

                if self.captureSession.canAddInput(input) {
                    self.captureSession.addInput(input)
                }

                // Configure camera for close-up text reading
                try camera.lockForConfiguration()
                if camera.isFocusModeSupported(.continuousAutoFocus) {
                    camera.focusMode = .continuousAutoFocus
                }
                if camera.isAutoFocusRangeRestrictionSupported {
                    // Restrict focus to near range — we're scanning tires up close
                    camera.autoFocusRangeRestriction = .near
                }
                camera.unlockForConfiguration()

            } catch {
                DispatchQueue.main.async {
                    self.cameraError = "Failed to configure camera: \(error.localizedDescription)"
                }
                return
            }

            // MARK: Video Output
            // This delivers frames to our OCR processor
            self.videoOutput.setSampleBufferDelegate(
                self.frameDelegate,
                queue: DispatchQueue(label: "com.smartpneu.camera.frames")
            )
            // Use BGRA pixel format — works well with Vision framework
            self.videoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
            // Drop frames if the OCR processor is busy (don't queue them up)
            self.videoOutput.alwaysDiscardsLateVideoFrames = true

            if self.captureSession.canAddOutput(self.videoOutput) {
                self.captureSession.addOutput(self.videoOutput)
            }

            self.captureSession.commitConfiguration()

            // Start the camera
            self.captureSession.startRunning()

            DispatchQueue.main.async {
                self.isCameraReady = true
            }
        }
    }

    // MARK: - Control

    func startCamera() {
        sessionQueue.async {
            if !self.captureSession.isRunning {
                self.captureSession.startRunning()
            }
        }
    }

    func stopCamera() {
        sessionQueue.async {
            if self.captureSession.isRunning {
                self.captureSession.stopRunning()
            }
        }
    }
}
