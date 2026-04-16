import SwiftUI

// MARK: - TireScannerView
// The main scanner screen. Shows the live camera feed with overlay
// guides and detected text highlights. This is the screen you'll use
// most — point at a tire, see the OCR results in real time.

struct TireScannerView: View {
    @StateObject private var cameraManager = CameraManager()
    @StateObject private var ocrProcessor = TireOCRProcessor()
    @State private var showResult = false

    var body: some View {
        ZStack {
            // Layer 1: Live camera feed (full screen)
            CameraPreviewView(session: cameraManager.captureSession)
                .ignoresSafeArea()

            // Layer 2: Semi-transparent overlay with scan zone
            ScanOverlay()

            // Layer 3: Detected text highlights
            TextHighlightsOverlay(texts: ocrProcessor.recognizedTexts)

            // Layer 4: UI controls and status
            VStack {
                // Top bar: status indicator
                HStack {
                    StatusBadge(state: ocrProcessor.scanState)
                    Spacer()
                }
                .padding()

                Spacer()

                // Detected spec preview (shown when a tire size is found)
                if let spec = ocrProcessor.detectedSpec {
                    DetectedSpecCard(spec: spec)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .animation(.spring(response: 0.3), value: ocrProcessor.detectedSpec != nil)
                }

                // Bottom bar: capture button
                HStack {
                    // Reset button
                    if ocrProcessor.scanState == .detected {
                        Button(action: { ocrProcessor.resetScan() }) {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.title2)
                                .foregroundColor(.white)
                                .frame(width: 50, height: 50)
                                .background(Color.black.opacity(0.5))
                                .clipShape(Circle())
                        }
                    }

                    Spacer()

                    // Capture / Confirm button
                    Button(action: {
                        if ocrProcessor.detectedSpec != nil {
                            ocrProcessor.confirmScan()
                            showResult = true
                        }
                    }) {
                        ZStack {
                            Circle()
                                .stroke(Color.white, lineWidth: 4)
                                .frame(width: 72, height: 72)

                            Circle()
                                .fill(ocrProcessor.detectedSpec != nil ? Color.orange : Color.white.opacity(0.3))
                                .frame(width: 60, height: 60)

                            if ocrProcessor.detectedSpec != nil {
                                Image(systemName: "checkmark")
                                    .font(.title)
                                    .fontWeight(.bold)
                                    .foregroundColor(.white)
                            }
                        }
                    }
                    .disabled(ocrProcessor.detectedSpec == nil)

                    Spacer()

                    // Placeholder for symmetry
                    Color.clear.frame(width: 50, height: 50)
                }
                .padding(.horizontal, 30)
                .padding(.bottom, 30)
            }
        }
        .onAppear {
            cameraManager.configure(frameDelegate: ocrProcessor)
        }
        .onDisappear {
            cameraManager.stopCamera()
        }
        .fullScreenCover(isPresented: $showResult) {
            if let spec = ocrProcessor.detectedSpec {
                ScanResultView(spec: spec) {
                    showResult = false
                    ocrProcessor.resetScan()
                }
            }
        }
    }
}

// MARK: - Scan Overlay
// Dark overlay with a clear "scan zone" rectangle in the center

struct ScanOverlay: View {
    var body: some View {
        GeometryReader { geometry in
            let scanWidth = geometry.size.width * 0.85
            let scanHeight: CGFloat = 120
            let centerY = geometry.size.height * 0.4

            ZStack {
                // Dark overlay
                Color.black.opacity(0.4)
                    .ignoresSafeArea()

                // Clear scan zone (cut out from overlay)
                RoundedRectangle(cornerRadius: 12)
                    .frame(width: scanWidth, height: scanHeight)
                    .position(x: geometry.size.width / 2, y: centerY)
                    .blendMode(.destinationOut)
            }
            .compositingGroup()

            // Scan zone border
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.orange, lineWidth: 2)
                .frame(width: scanWidth, height: scanHeight)
                .position(x: geometry.size.width / 2, y: centerY)

            // Helper text
            Text("Align tire size text in the box")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(.white.opacity(0.8))
                .position(x: geometry.size.width / 2, y: centerY + scanHeight / 2 + 24)
        }
    }
}

// MARK: - Text Highlights Overlay
// Shows green/orange boxes around detected text

struct TextHighlightsOverlay: View {
    let texts: [RecognizedText]

    var body: some View {
        GeometryReader { geometry in
            ForEach(texts) { text in
                // Vision gives coordinates with origin at bottom-left,
                // but SwiftUI uses top-left. We need to flip Y.
                let rect = CGRect(
                    x: text.boundingBox.origin.x * geometry.size.width,
                    y: (1 - text.boundingBox.origin.y - text.boundingBox.height) * geometry.size.height,
                    width: text.boundingBox.width * geometry.size.width,
                    height: text.boundingBox.height * geometry.size.height
                )

                RoundedRectangle(cornerRadius: 4)
                    .stroke(text.isTireSize ? Color.orange : Color.green.opacity(0.5), lineWidth: text.isTireSize ? 3 : 1)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
            }
        }
    }
}

// MARK: - Status Badge

struct StatusBadge: View {
    let state: ScanState

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(stateColor)
                .frame(width: 8, height: 8)
            Text(stateText)
                .font(.caption)
                .fontWeight(.semibold)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.6))
        .cornerRadius(20)
        .foregroundColor(.white)
    }

    private var stateColor: Color {
        switch state {
        case .scanning: return .green
        case .detected: return .orange
        case .captured: return .blue
        case .error: return .red
        }
    }

    private var stateText: String {
        switch state {
        case .scanning: return "Scanning..."
        case .detected: return "Tire detected!"
        case .captured: return "Captured"
        case .error(let msg): return msg
        }
    }
}

// MARK: - Detected Spec Card
// Shows a preview card of the parsed tire info

struct DetectedSpecCard: View {
    let spec: TireSpec

    var body: some View {
        VStack(spacing: 8) {
            // Size
            Text(spec.formattedSize)
                .font(.title)
                .fontWeight(.bold)
                .foregroundColor(.orange)

            // Brand (if detected)
            if !spec.marque.isEmpty {
                Text(spec.marque)
                    .font(.headline)
                    .foregroundColor(.white)
            }

            // Details row
            HStack(spacing: 16) {
                if !spec.largeur.isEmpty {
                    DetailChip(label: "Largeur", value: spec.largeur)
                }
                if !spec.hauteur.isEmpty {
                    DetailChip(label: "Hauteur", value: spec.hauteur)
                }
                if !spec.rayon.isEmpty {
                    DetailChip(label: "Rayon", value: "R\(spec.rayon)")
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(Color.black.opacity(0.75))
        .cornerRadius(16)
        .padding(.horizontal)
    }
}

struct DetailChip: View {
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundColor(.gray)
            Text(value)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundColor(.white)
        }
    }
}

// MARK: - Preview
#Preview {
    TireScannerView()
}
