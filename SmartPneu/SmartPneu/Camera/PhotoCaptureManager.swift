import AVFoundation
import Combine
import UIKit

// MARK: - PhotoCaptureManager
// Handles high-quality still photo capture from the iPhone camera.
// Configured for maximum quality: 48MP on Pro models, locked white balance,
// and optimized exposure for product photography.

class PhotoCaptureManager: NSObject, ObservableObject {

    let captureSession = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let sessionQueue = DispatchQueue(label: "com.smartpneu.photo.session")

    @Published var isCameraReady = false
    @Published var capturedImage: UIImage?
    @Published var cameraError: String?
    @Published var isCapturing = false

    // Exposure compensation: 0.0 = neutral, range typically -8…+8
    // Default to a slight boost (+1.0 EV) for dark tires — user can adjust
    @Published var exposureBias: Float = 1.0

    // Expose the device's min/max bias so the UI can build a slider
    @Published var minExposureBias: Float = -2.0
    @Published var maxExposureBias: Float = 4.0

    private var cameraDevice: AVCaptureDevice?

    // Completion handler for photo capture
    private var photoCaptureCompletion: ((UIImage?) -> Void)?

    // MARK: - Setup

    func configure() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            setupSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                if granted { self?.setupSession() }
                else {
                    DispatchQueue.main.async {
                        self?.cameraError = "Accès caméra refusé. Allez dans Réglages → SmartPneu → Caméra."
                    }
                }
            }
        default:
            DispatchQueue.main.async {
                self.cameraError = "Accès caméra refusé. Allez dans Réglages → SmartPneu → Caméra."
            }
        }
    }

    private func setupSession() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }

            self.captureSession.beginConfiguration()

            // Use highest quality preset for studio-like photos
            self.captureSession.sessionPreset = .photo

            // Get the main back camera (48MP on Pro models)
            guard let camera = AVCaptureDevice.default(
                .builtInWideAngleCamera,
                for: .video,
                position: .back
            ) else {
                DispatchQueue.main.async { self.cameraError = "Caméra introuvable" }
                return
            }

            do {
                let input = try AVCaptureDeviceInput(device: camera)
                if self.captureSession.canAddInput(input) {
                    self.captureSession.addInput(input)
                }

                // Configure camera for product photography of dark tires
                try camera.lockForConfiguration()

                // Continuous autofocus for framing
                if camera.isFocusModeSupported(.continuousAutoFocus) {
                    camera.focusMode = .continuousAutoFocus
                }

                // Lock white balance for consistency across shots
                if camera.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                    camera.whiteBalanceMode = .continuousAutoWhiteBalance
                }

                // Use continuous auto-exposure — let the sensor adapt to the scene.
                // The user controls overall brightness via exposureTargetBias (EV slider).
                if camera.isExposureModeSupported(.continuousAutoExposure) {
                    camera.exposureMode = .continuousAutoExposure
                }

                // Apply the initial exposure bias (+1 EV for dark tires)
                let clampedBias = max(camera.minExposureTargetBias,
                                      min(camera.maxExposureTargetBias, self.exposureBias))
                camera.setExposureTargetBias(clampedBias, completionHandler: nil)

                camera.unlockForConfiguration()

                // Store device reference + publish real min/max for slider
                self.cameraDevice = camera
                DispatchQueue.main.async {
                    self.minExposureBias = camera.minExposureTargetBias
                    self.maxExposureBias = camera.maxExposureTargetBias
                }

            } catch {
                DispatchQueue.main.async {
                    self.cameraError = "Erreur caméra: \(error.localizedDescription)"
                }
                return
            }

            // Configure photo output for maximum quality
            if self.captureSession.canAddOutput(self.photoOutput) {
                self.captureSession.addOutput(self.photoOutput)

                // Enable highest resolution capture (48MP on Pro)
                // Use maxPhotoDimensions for iOS 17+
                let maxDimensions = self.photoOutput.maxPhotoDimensions
                self.photoOutput.maxPhotoDimensions = maxDimensions
                self.photoOutput.maxPhotoQualityPrioritization = .quality
            }

            self.captureSession.commitConfiguration()
            self.captureSession.startRunning()

            DispatchQueue.main.async {
                self.isCameraReady = true
            }
        }
    }

    // MARK: - Capture

    /// Take a high-quality photo
    func capturePhoto(completion: @escaping (UIImage?) -> Void) {
        guard !isCapturing else { return }

        DispatchQueue.main.async { self.isCapturing = true }
        self.photoCaptureCompletion = completion

        let settings = AVCapturePhotoSettings()

        // Use max resolution (48MP on Pro models)
        settings.maxPhotoDimensions = self.photoOutput.maxPhotoDimensions

        // Flash off — for consistent lighting (you control your studio lights)
        settings.flashMode = .off

        self.photoOutput.capturePhoto(with: settings, delegate: self)
    }

    // MARK: - Exposure Adjustment

    /// Call this when the user moves the exposure slider.
    func updateExposureBias(_ newBias: Float) {
        sessionQueue.async { [weak self] in
            guard let self = self, let camera = self.cameraDevice else { return }
            do {
                try camera.lockForConfiguration()
                let clamped = max(camera.minExposureTargetBias,
                                  min(camera.maxExposureTargetBias, newBias))
                camera.setExposureTargetBias(clamped, completionHandler: nil)
                camera.unlockForConfiguration()
                DispatchQueue.main.async { self.exposureBias = clamped }
            } catch {
                // Silently ignore — transient lock failures are fine
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

// MARK: - Photo Capture Delegate
// Called automatically when the photo is ready

extension PhotoCaptureManager: AVCapturePhotoCaptureDelegate {

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        DispatchQueue.main.async { self.isCapturing = false }

        if let error = error {
            DispatchQueue.main.async {
                self.cameraError = "Erreur capture: \(error.localizedDescription)"
            }
            photoCaptureCompletion?(nil)
            return
        }

        // Convert the photo data to a UIImage
        guard let imageData = photo.fileDataRepresentation(),
              let image = UIImage(data: imageData)
        else {
            photoCaptureCompletion?(nil)
            return
        }

        DispatchQueue.main.async {
            self.capturedImage = image
        }
        photoCaptureCompletion?(image)
    }
}
