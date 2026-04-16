import SwiftUI
import AVFoundation

// MARK: - CameraPreviewView
// SwiftUI can't directly display a camera feed, so we need to wrap
// a UIKit view (AVCaptureVideoPreviewLayer) in a SwiftUI-compatible wrapper.
// This is called a UIViewRepresentable — it's the bridge between UIKit and SwiftUI.

struct CameraPreviewView: UIViewRepresentable {

    // The capture session from our CameraManager
    let session: AVCaptureSession

    func makeUIView(context: Context) -> CameraPreviewUIView {
        let view = CameraPreviewUIView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill // Fill the screen
        return view
    }

    func updateUIView(_ uiView: CameraPreviewUIView, context: Context) {
        // Nothing to update — the session handles everything
    }
}

// The actual UIKit view that contains the preview layer
class CameraPreviewUIView: UIView {

    // This layer renders the live camera feed
    let previewLayer = AVCaptureVideoPreviewLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.addSublayer(previewLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // When the view resizes (rotation, etc.), resize the preview to match
    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer.frame = bounds
    }
}
