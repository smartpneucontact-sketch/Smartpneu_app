import SwiftUI
import PhotosUI

// MARK: - StudioPhotoView
// Flow: Enter SKU → Take multiple photos → Review & process → New SKU
//
// 1. User enters a SKU (999–999999)
// 2. Camera opens, user takes multiple photos of the same tire
// 3. Thumbnails appear at the bottom as photos are taken
// 4. User taps "Traiter" to run background removal on all photos
// 5. User reviews processed photos, saves them
// 6. User can start a new SKU

struct StudioPhotoView: View {
    @StateObject private var photoManager = PhotoCaptureManager()
    @StateObject private var bgRemover = BackgroundRemover()

    // Flow state
    @State private var currentStep: StudioStep = .skuEntry
    @State private var skuText: String = ""
    @State private var currentSKU: String = ""
    @State private var skuError: String?

    // Photos for current SKU
    @State private var currentPhotoMode: PhotoMode = .side
    @State private var capturedPhotos: [CapturedPhoto] = []
    @State private var selectedPhotoIndex: Int? = nil
    @State private var isProcessingAll = false
    @State private var processedCount = 0
    @State private var selectedBackground: BackgroundRemover.BackgroundStyle = .white
    @State private var selectedEdgeQuality: BackgroundRemover.EdgeQuality = .erodeFeather

    enum StudioStep {
        case skuEntry       // Enter SKU number
        case shooting       // Camera live, taking photos
        case reviewing      // Review all photos, process backgrounds
    }

    var body: some View {
        NavigationStack {
            Group {
                switch currentStep {
                case .skuEntry:
                    SKUEntryView(
                        skuText: $skuText,
                        skuError: $skuError,
                        onConfirm: confirmSKU
                    )

                case .shooting:
                    ShootingView(
                        photoManager: photoManager,
                        sku: currentSKU,
                        photoMode: $currentPhotoMode,
                        capturedPhotos: $capturedPhotos,
                        onCapture: capturePhoto,
                        onDone: { currentStep = .reviewing },
                        onDeletePhoto: deletePhoto
                    )
                    .toolbar(.hidden, for: .tabBar)
                    .navigationBarHidden(true)

                case .reviewing:
                    ReviewView(
                        sku: currentSKU,
                        capturedPhotos: $capturedPhotos,
                        selectedPhotoIndex: $selectedPhotoIndex,
                        selectedBackground: $selectedBackground,
                        selectedEdgeQuality: $selectedEdgeQuality,
                        isProcessing: isProcessingAll,
                        processedCount: processedCount,
                        onProcessAll: processAllPhotos,
                        onChangeBackground: changeBackground,
                        onChangeEdgeQuality: changeEdgeQuality,
                        onSaveAll: saveAllPhotos,
                        onNewSKU: startNewSKU,
                        onBackToCamera: { currentStep = .shooting; photoManager.startCamera() }
                    )
                }
            }
            .navigationTitle(currentStep == .skuEntry ? "Studio Photo" : "SKU \(currentSKU)")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear { photoManager.configure() }
        .onDisappear { photoManager.stopCamera() }
    }

    // MARK: - Actions

    private func confirmSKU() {
        // Validate SKU: must be a number between 999 and 999999
        guard let skuNumber = Int(skuText),
              skuNumber >= 999 && skuNumber <= 999999 else {
            skuError = "Le SKU doit être un nombre entre 999 et 999 999"
            return
        }
        skuError = nil
        currentSKU = skuText
        capturedPhotos = []
        selectedPhotoIndex = nil
        processedCount = 0
        currentStep = .shooting
        photoManager.startCamera()
    }

    private func capturePhoto() {
        let mode = currentPhotoMode
        photoManager.capturePhoto { image in
            guard let image = image else { return }
            let photo = CapturedPhoto(
                original: image,
                index: capturedPhotos.count + 1,
                mode: mode
            )
            capturedPhotos.append(photo)
        }
    }

    private func deletePhoto(at index: Int) {
        guard index >= 0 && index < capturedPhotos.count else { return }
        capturedPhotos.remove(at: index)
        // Re-number
        for i in 0..<capturedPhotos.count {
            capturedPhotos[i].index = i + 1
        }
    }

    private func processAllPhotos() {
        isProcessingAll = true
        processedCount = 0

        for i in 0..<capturedPhotos.count {
            bgRemover.removeBackground(
                from: capturedPhotos[i].original,
                backgroundStyle: selectedBackground,
                edgeQuality: selectedEdgeQuality,
                photoMode: capturedPhotos[i].mode
            ) { result, errorMessage in
                capturedPhotos[i].processed = result
                capturedPhotos[i].processingError = errorMessage
                processedCount += 1
                if processedCount == capturedPhotos.count {
                    isProcessingAll = false
                }
            }
        }
    }

    private func changeBackground(_ style: BackgroundRemover.BackgroundStyle) {
        selectedBackground = style
        processAllPhotos()
    }

    private func changeEdgeQuality(_ quality: BackgroundRemover.EdgeQuality) {
        selectedEdgeQuality = quality
        processAllPhotos()
    }

    private func saveAllPhotos() {
        for photo in capturedPhotos {
            if let processed = photo.processed {
                BackgroundRemover.saveToPhotoLibrary(processed) { _ in }
            }
        }
    }

    private func startNewSKU() {
        currentStep = .skuEntry
        skuText = ""
        currentSKU = ""
        currentPhotoMode = .side
        capturedPhotos = []
        selectedPhotoIndex = nil
        processedCount = 0
        photoManager.stopCamera()
    }
}

// MARK: - Photo Mode

enum PhotoMode: String, CaseIterable {
    case side = "Côté"       // Single tire side view → circle guide, square crop
    case front = "Face 2"    // 2 tires stacked front view → rectangle guide, portrait crop (3:4)
    case front4 = "Face 4"   // 4 tires stacked front view → tall rectangle guide, tall portrait crop (3:8)
}

// MARK: - CapturedPhoto Model

struct CapturedPhoto: Identifiable {
    let id = UUID()
    let original: UIImage
    var processed: UIImage?
    var index: Int
    var mode: PhotoMode = .side
    var processingError: String? = nil
}

// MARK: - Framing Guide Overlay
// Dim mask with a bright window cut out, sized per photo mode so the
// operator frames tires with visible margin (~70-85% of viewport).

private struct FramingGuideOverlay: View {
    let photoMode: PhotoMode

    var body: some View {
        GeometryReader { geo in
            let (windowSize, isCircle) = windowGeometry(for: photoMode, in: geo.size)
            ZStack {
                Color.black.opacity(0.35)
                    .mask {
                        Rectangle()
                            .overlay(alignment: .center) {
                                if isCircle {
                                    Circle()
                                        .frame(width: windowSize.width, height: windowSize.height)
                                        .blendMode(.destinationOut)
                                } else {
                                    RoundedRectangle(cornerRadius: 12)
                                        .frame(width: windowSize.width, height: windowSize.height)
                                        .blendMode(.destinationOut)
                                }
                            }
                            .compositingGroup()
                    }

                Group {
                    if isCircle {
                        Circle().stroke(Color.orange, lineWidth: 2)
                    } else {
                        RoundedRectangle(cornerRadius: 12).stroke(Color.orange, lineWidth: 2)
                    }
                }
                .frame(width: windowSize.width, height: windowSize.height)

                VStack {
                    Spacer()
                    Text(captionText(for: photoMode))
                        .font(.caption)
                        .fontWeight(.semibold)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.black.opacity(0.5))
                        .foregroundColor(.white)
                        .cornerRadius(8)
                        .padding(.bottom, 12)
                }
            }
            .allowsHitTesting(false)
        }
    }

    private func windowGeometry(for mode: PhotoMode, in size: CGSize) -> (CGSize, Bool) {
        switch mode {
        case .side:
            let d = min(size.width, size.height) * 0.70
            return (CGSize(width: d, height: d), true)
        case .front:
            let h = size.height * 0.75
            return (CGSize(width: h * (3.0 / 4.0), height: h), false)
        case .front4:
            let h = size.height * 0.85
            return (CGSize(width: h * (3.0 / 8.0), height: h), false)
        }
    }

    private func captionText(for mode: PhotoMode) -> String {
        switch mode {
        case .side:   return "Cadrer le pneu DANS le cercle (marge visible)"
        case .front:  return "Cadrer les 2 pneus DANS le rectangle (reculer si trop près)"
        case .front4: return "Cadrer les 4 pneus DANS le rectangle (reculer si trop près)"
        }
    }
}

// MARK: - SKU Entry View

struct SKUEntryView: View {
    @Binding var skuText: String
    @Binding var skuError: String?
    let onConfirm: () -> Void

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            // Icon
            Image(systemName: "barcode")
                .font(.system(size: 60))
                .foregroundColor(.orange)

            // Title
            VStack(spacing: 8) {
                Text("Nouveau pneu")
                    .font(.title)
                    .fontWeight(.bold)
                Text("Entrez le numéro SKU avant de photographier")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            // SKU input
            VStack(spacing: 8) {
                TextField("Numéro SKU", text: $skuText)
                    .keyboardType(.numberPad)
                    .font(.title2)
                    .fontWeight(.semibold)
                    .multilineTextAlignment(.center)
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(12)
                    .padding(.horizontal, 40)

                if let error = skuError {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                }

                Text("Entre 999 et 999 999")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // Confirm button
            Button(action: onConfirm) {
                HStack {
                    Image(systemName: "camera.fill")
                    Text("Commencer les photos")
                }
                .font(.headline)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding()
                .background(skuText.isEmpty ? Color.gray : Color.orange)
                .cornerRadius(14)
                .padding(.horizontal, 40)
            }
            .disabled(skuText.isEmpty)

            Spacer()
        }
    }
}

// MARK: - Shooting View
// Camera live with thumbnail strip at bottom

struct ShootingView: View {
    @ObservedObject var photoManager: PhotoCaptureManager
    let sku: String
    @Binding var photoMode: PhotoMode
    @Binding var capturedPhotos: [CapturedPhoto]
    let onCapture: () -> Void
    let onDone: () -> Void
    let onDeletePhoto: (Int) -> Void

    @State private var sliderBias: Float = 1.0
    @State private var showExposureSlider = false
    @State private var selectedPickerItems: [PhotosPickerItem] = []
    @State private var isLoadingLibraryPhotos = false

    private func syncSliderFromManager() {
        sliderBias = photoManager.exposureBias
    }

    private func updateOrientation(for mode: PhotoMode) {
        if mode == .front4 {
            OrientationManager.shared.forceLandscape()
        } else {
            OrientationManager.shared.forcePortrait()
        }
    }

    private var isLandscape: Bool { photoMode == .front4 }

    var body: some View {
        ZStack {
            // Live camera feed
            CameraPreviewView(session: photoManager.captureSession)
                .ignoresSafeArea()

            if isLandscape {
                // MARK: Landscape layout (Face 4)
                landscapeBody
            } else {
                // MARK: Portrait layout (Côté / Face 2)
                portraitBody
            }

            // Vertical exposure slider (right edge) — portrait only
            if showExposureSlider && !isLandscape {
                HStack {
                    Spacer()
                    VStack(spacing: 6) {
                        Image(systemName: "sun.max.fill")
                            .font(.caption)
                            .foregroundColor(.orange)

                        Text(String(format: "%+.1f", sliderBias))
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)

                        Slider(
                            value: Binding(
                                get: { sliderBias },
                                set: { newVal in
                                    sliderBias = newVal
                                    photoManager.updateExposureBias(newVal)
                                }
                            ),
                            in: Float(photoManager.minExposureBias)...Float(photoManager.maxExposureBias),
                            step: 0.1
                        )
                        .frame(width: 200)
                        .rotationEffect(.degrees(-90))
                        .frame(width: 40, height: 200)
                        .tint(.orange)

                        Image(systemName: "sun.min")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.6))
                    }
                    .padding(.vertical, 20)
                    .padding(.horizontal, 8)
                    .background(Color.black.opacity(0.5))
                    .cornerRadius(16)
                    .padding(.trailing, 8)
                }
                .padding(.top, 60)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }

            // Error message
            if let error = photoManager.cameraError {
                VStack {
                    Text(error)
                        .foregroundColor(.white)
                        .padding()
                        .background(Color.red.opacity(0.8))
                        .cornerRadius(10)
                    Spacer()
                }
                .padding(.top, 60)
            }
        }
        .onAppear {
            syncSliderFromManager()
            updateOrientation(for: photoMode)
        }
        .onDisappear {
            // Restore portrait when leaving the shooting screen
            OrientationManager.shared.forcePortrait()
        }
        .onChange(of: photoMode) { _, newMode in
            updateOrientation(for: newMode)
        }
        .onChange(of: selectedPickerItems) { _, newItems in
            guard !newItems.isEmpty else { return }
            isLoadingLibraryPhotos = true
            let mode = photoMode

            Task {
                for item in newItems {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        let photo = CapturedPhoto(
                            original: image,
                            index: capturedPhotos.count + 1,
                            mode: mode
                        )
                        await MainActor.run {
                            capturedPhotos.append(photo)
                        }
                    }
                }
                await MainActor.run {
                    selectedPickerItems = []
                    isLoadingLibraryPhotos = false
                }
            }
        }
        .overlay {
            if isLoadingLibraryPhotos {
                VStack(spacing: 12) {
                    ProgressView()
                        .tint(.orange)
                    Text("Importation des photos...")
                        .font(.caption)
                        .foregroundColor(.white)
                }
                .padding(20)
                .background(Color.black.opacity(0.7))
                .cornerRadius(12)
            }
        }
    }

    // MARK: - Portrait Layout (Côté / Face 2)

    private var portraitBody: some View {
        VStack(spacing: 0) {
            topBar

            FramingGuideOverlay(photoMode: photoMode)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            thumbnailStrip
            bottomButtons
        }
    }

    // MARK: - Landscape Layout (Face 4)

    private var landscapeBody: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                // Left side: framing guide centered over camera (full screen)
                FramingGuideOverlay(photoMode: photoMode)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Right side: compact controls panel
                VStack(spacing: 8) {
                    // Mode toggle
                    VStack(spacing: 0) {
                        ForEach(PhotoMode.allCases, id: \.self) { mode in
                            Button(action: { withAnimation(.easeInOut(duration: 0.15)) { photoMode = mode } }) {
                                Text(mode.rawValue)
                                    .font(.system(size: 10))
                                    .fontWeight(.bold)
                                    .frame(width: 50)
                                    .padding(.vertical, 4)
                                    .background(photoMode == mode ? Color.orange : Color.black.opacity(0.4))
                                    .foregroundColor(.white)
                            }
                        }
                    }
                    .cornerRadius(8)

                    // Photo count
                    Text("\(capturedPhotos.count)")
                        .font(.caption2)
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                        .padding(5)
                        .background(Color.black.opacity(0.6))
                        .cornerRadius(8)

                    // Gallery
                    PhotosPicker(
                        selection: $selectedPickerItems,
                        maxSelectionCount: 20,
                        matching: .images
                    ) {
                        Image(systemName: "photo.on.rectangle")
                            .font(.body)
                            .foregroundColor(isLoadingLibraryPhotos ? .gray : .white)
                    }
                    .disabled(isLoadingLibraryPhotos)

                    // Capture button
                    Button(action: onCapture) {
                        ZStack {
                            Circle()
                                .stroke(Color.white, lineWidth: 3)
                                .frame(width: 50, height: 50)
                            Circle()
                                .fill(Color.white)
                                .frame(width: 40, height: 40)
                        }
                    }
                    .disabled(!photoManager.isCameraReady || photoManager.isCapturing)
                    .opacity(photoManager.isCameraReady ? 1 : 0.4)

                    // Exposure
                    Button(action: { withAnimation(.easeInOut(duration: 0.2)) { showExposureSlider.toggle() } }) {
                        Image(systemName: showExposureSlider ? "sun.max.fill" : "sun.max")
                            .font(.body)
                            .foregroundColor(showExposureSlider ? .orange : .white)
                    }

                    if showExposureSlider {
                        Slider(
                            value: Binding(
                                get: { sliderBias },
                                set: { newVal in
                                    sliderBias = newVal
                                    photoManager.updateExposureBias(newVal)
                                }
                            ),
                            in: Float(photoManager.minExposureBias)...Float(photoManager.maxExposureBias),
                            step: 0.1
                        )
                        .frame(width: 44)
                        .rotationEffect(.degrees(-90))
                        .frame(width: 26, height: 60)
                        .tint(.orange)
                    }

                    // Done button
                    Button(action: onDone) {
                        VStack(spacing: 2) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.title3)
                            Text("OK")
                                .font(.system(size: 9, weight: .bold))
                        }
                        .foregroundColor(capturedPhotos.isEmpty ? .gray : .green)
                    }
                    .disabled(capturedPhotos.isEmpty)
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 6)
                .frame(width: 68)
                .background(Color.black.opacity(0.4))
                .ignoresSafeArea(edges: .vertical)
            }
            .ignoresSafeArea(edges: .bottom)
        }
    }

    // MARK: - Shared Sub-views

    private var topBar: some View {
        HStack {
            HStack(spacing: 6) {
                Image(systemName: "barcode")
                    .font(.caption)
                Text("SKU \(sku)")
                    .font(.caption)
                    .fontWeight(.bold)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.6))
            .cornerRadius(20)
            .foregroundColor(.white)

            Spacer()

            // Side / Front 2 / Front 4 mode toggle
            HStack(spacing: 0) {
                ForEach(PhotoMode.allCases, id: \.self) { mode in
                    Button(action: { withAnimation(.easeInOut(duration: 0.15)) { photoMode = mode } }) {
                        HStack(spacing: 3) {
                            Image(systemName: mode == .side ? "circle" : "rectangle.portrait")
                                .font(.system(size: 9))
                            Text(mode.rawValue)
                                .font(.caption2)
                                .fontWeight(.bold)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(photoMode == mode ? Color.orange : Color.black.opacity(0.4))
                        .foregroundColor(.white)
                    }
                }
            }
            .cornerRadius(16)

            Spacer()

            // Photo count
            HStack(spacing: 4) {
                Image(systemName: "photo.on.rectangle")
                    .font(.caption)
                Text("\(capturedPhotos.count)")
                    .font(.caption)
                    .fontWeight(.bold)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.6))
            .cornerRadius(20)
            .foregroundColor(.white)
        }
        .padding()
    }

    private var thumbnailStrip: some View {
        Group {
            if !capturedPhotos.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(capturedPhotos.enumerated()), id: \.element.id) { index, photo in
                            ZStack(alignment: .topTrailing) {
                                Image(uiImage: photo.original)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 60, height: 60)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(Color.orange, lineWidth: 2)
                                    )

                                Button(action: { onDeletePhoto(index) }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 16))
                                        .foregroundColor(.red)
                                        .background(Color.white.clipShape(Circle()))
                                }
                                .offset(x: 4, y: -4)

                                VStack(spacing: 2) {
                                    Text("\(photo.index)")
                                        .font(.caption2)
                                        .fontWeight(.bold)
                                        .foregroundColor(.white)
                                        .padding(4)
                                        .background(Color.orange)
                                        .clipShape(Circle())

                                    Image(systemName: photo.mode == .side ? "circle" : (photo.mode == .front4 ? "rectangle.split.2x1" : "rectangle.portrait"))
                                        .font(.system(size: 8))
                                        .foregroundColor(.white)
                                        .padding(3)
                                        .background(Color.black.opacity(0.6))
                                        .clipShape(Circle())
                                }
                                .offset(x: -4, y: -4)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                            }
                        }
                    }
                    .padding(.horizontal)
                }
                .frame(height: 70)
                .padding(.bottom, 8)
            }
        }
    }

    private var bottomButtons: some View {
        HStack(spacing: 24) {
            PhotosPicker(
                selection: $selectedPickerItems,
                maxSelectionCount: 20,
                matching: .images
            ) {
                VStack(spacing: 4) {
                    Image(systemName: "photo.on.rectangle")
                        .font(.title)
                    Text("Galerie")
                        .font(.caption2)
                }
                .foregroundColor(isLoadingLibraryPhotos ? .gray : .white)
            }
            .disabled(isLoadingLibraryPhotos)

            Button(action: onDone) {
                VStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title)
                    Text("Terminer")
                        .font(.caption2)
                }
                .foregroundColor(capturedPhotos.isEmpty ? .gray : .green)
            }
            .disabled(capturedPhotos.isEmpty)

            Button(action: onCapture) {
                ZStack {
                    Circle()
                        .stroke(Color.white, lineWidth: 4)
                        .frame(width: 72, height: 72)
                    Circle()
                        .fill(Color.white)
                        .frame(width: 60, height: 60)
                }
            }
            .disabled(!photoManager.isCameraReady || photoManager.isCapturing)
            .opacity(photoManager.isCameraReady ? 1 : 0.4)

            Button(action: { withAnimation(.easeInOut(duration: 0.2)) { showExposureSlider.toggle() } }) {
                VStack(spacing: 4) {
                    Image(systemName: showExposureSlider ? "sun.max.fill" : "sun.max")
                        .font(.title)
                    Text("Exposition")
                        .font(.caption2)
                }
                .foregroundColor(showExposureSlider ? .orange : .white)
            }
        }
        .padding(.bottom, 30)
    }
}

// MARK: - Review View
// Shows all captured photos, process backgrounds, save

struct ReviewView: View {
    let sku: String
    @Binding var capturedPhotos: [CapturedPhoto]
    @Binding var selectedPhotoIndex: Int?
    @Binding var selectedBackground: BackgroundRemover.BackgroundStyle
    @Binding var selectedEdgeQuality: BackgroundRemover.EdgeQuality
    let isProcessing: Bool
    let processedCount: Int
    let onProcessAll: () -> Void
    let onChangeBackground: (BackgroundRemover.BackgroundStyle) -> Void
    let onChangeEdgeQuality: (BackgroundRemover.EdgeQuality) -> Void
    let onSaveAll: () -> Void
    let onNewSKU: () -> Void
    let onBackToCamera: () -> Void

    @State private var showOriginal = false
    @State private var allSaved = false

    var body: some View {
        VStack(spacing: 0) {
            // Main image display
            ZStack {
                CheckerboardView()

                if let index = selectedPhotoIndex, index < capturedPhotos.count {
                    let photo = capturedPhotos[index]

                    if showOriginal {
                        Image(uiImage: photo.original)
                            .resizable()
                            .scaledToFit()
                    } else if let processed = photo.processed {
                        Image(uiImage: processed)
                            .resizable()
                            .scaledToFit()
                    } else {
                        Image(uiImage: photo.original)
                            .resizable()
                            .scaledToFit()
                            .overlay(
                                Text(photo.processingError ?? "Non traité")
                                    .font(.caption)
                                    .multilineTextAlignment(.center)
                                    .padding(6)
                                    .background(Color.black.opacity(0.6))
                                    .foregroundColor(.white)
                                    .cornerRadius(6)
                            )
                    }
                } else {
                    VStack {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 40))
                            .foregroundColor(.secondary)
                        Text("\(capturedPhotos.count) photo\(capturedPhotos.count > 1 ? "s" : "")")
                            .foregroundColor(.secondary)
                    }
                }

                // Processing overlay
                if isProcessing {
                    VStack {
                        ProgressView()
                            .tint(.orange)
                        Text("Traitement \(processedCount)/\(capturedPhotos.count)...")
                            .font(.caption)
                            .foregroundColor(.white)
                    }
                    .padding()
                    .background(Color.black.opacity(0.7))
                    .cornerRadius(12)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(white: 0.95))

            // Toggle original/processed
            if selectedPhotoIndex != nil {
                Button(action: { showOriginal.toggle() }) {
                    HStack {
                        Image(systemName: showOriginal ? "photo" : "photo.artframe")
                        Text(showOriginal ? "Original" : "Fond supprimé")
                    }
                    .font(.caption)
                    .padding(.vertical, 6)
                }
            }

            // Thumbnail strip
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(capturedPhotos.enumerated()), id: \.element.id) { index, photo in
                        Button(action: { selectedPhotoIndex = index }) {
                            ZStack {
                                if let processed = photo.processed {
                                    Image(uiImage: processed)
                                        .resizable()
                                        .scaledToFill()
                                } else {
                                    Image(uiImage: photo.original)
                                        .resizable()
                                        .scaledToFill()
                                }
                            }
                            .frame(width: 56, height: 56)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(
                                        selectedPhotoIndex == index ? Color.orange : Color.clear,
                                        lineWidth: 3
                                    )
                            )
                        }
                    }
                }
                .padding(.horizontal)
            }
            .frame(height: 64)
            .padding(.vertical, 8)

            // Background style picker
            HStack(spacing: 16) {
                BackgroundButton(color: .white, label: "Blanc", isSelected: isWhite, action: { onChangeBackground(.white) })
                BackgroundButton(color: Color(white: 0.95), label: "Gris", isSelected: isGray, action: { onChangeBackground(.lightGray) })
                BackgroundButton(color: nil, label: "Transparent", isSelected: isTransparent, action: { onChangeBackground(.transparent) })
            }
            .padding(.vertical, 4)

            // Edge quality picker
            HStack(spacing: 0) {
                ForEach(BackgroundRemover.EdgeQuality.allCases, id: \.self) { quality in
                    Button(action: { onChangeEdgeQuality(quality) }) {
                        Text(quality.rawValue)
                            .font(.caption2)
                            .fontWeight(selectedEdgeQuality == quality ? .bold : .regular)
                            .foregroundColor(selectedEdgeQuality == quality ? .white : .secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(selectedEdgeQuality == quality ? Color.orange : Color(.systemGray5))
                            .cornerRadius(8)
                    }
                }
            }
            .padding(.bottom, 4)

            // Action buttons
            VStack(spacing: 10) {
                // Process button (if not yet processed)
                let hasUnprocessed = capturedPhotos.contains(where: { $0.processed == nil })
                if hasUnprocessed {
                    Button(action: onProcessAll) {
                        HStack {
                            Image(systemName: "wand.and.stars")
                            Text("Supprimer les fonds (\(capturedPhotos.count) photos)")
                        }
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.orange)
                        .cornerRadius(12)
                    }
                    .disabled(isProcessing)
                }

                HStack(spacing: 12) {
                    // Back to camera (add more photos)
                    Button(action: onBackToCamera) {
                        HStack {
                            Image(systemName: "camera.fill")
                            Text("+ Photos")
                        }
                        .font(.subheadline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.gray.opacity(0.7))
                        .cornerRadius(12)
                    }

                    // Save all
                    let allProcessed = !capturedPhotos.contains(where: { $0.processed == nil })
                    Button(action: {
                        onSaveAll()
                        allSaved = true
                    }) {
                        HStack {
                            Image(systemName: allSaved ? "checkmark.circle.fill" : "square.and.arrow.down")
                            Text(allSaved ? "Sauvegardé!" : "Tout sauvegarder")
                        }
                        .font(.subheadline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(allSaved ? Color.green : (allProcessed ? Color.blue : Color.gray.opacity(0.4)))
                        .cornerRadius(12)
                    }
                    .disabled(!allProcessed)
                }

                // New SKU
                Button(action: onNewSKU) {
                    HStack {
                        Image(systemName: "barcode.viewfinder")
                        Text("Nouveau SKU")
                    }
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(.orange)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.orange.opacity(0.1))
                    .cornerRadius(12)
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 16)
        }
        .onAppear {
            if selectedPhotoIndex == nil && !capturedPhotos.isEmpty {
                selectedPhotoIndex = 0
            }
        }
    }

    private var isWhite: Bool { if case .white = selectedBackground { return true }; return false }
    private var isGray: Bool { if case .lightGray = selectedBackground { return true }; return false }
    private var isTransparent: Bool { if case .transparent = selectedBackground { return true }; return false }
}

// MARK: - Background Button

struct BackgroundButton: View {
    let color: Color?
    let label: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                ZStack {
                    if let color = color {
                        Circle().fill(color).frame(width: 36, height: 36)
                    } else {
                        Circle()
                            .fill(.linearGradient(colors: [.white, .gray.opacity(0.3)], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 36, height: 36)
                    }
                    Circle()
                        .stroke(isSelected ? Color.orange : Color.gray.opacity(0.3), lineWidth: isSelected ? 3 : 1)
                        .frame(width: 36, height: 36)
                }
                Text(label)
                    .font(.caption2)
                    .foregroundColor(isSelected ? .orange : .secondary)
            }
        }
    }
}

// MARK: - Checkerboard View

struct CheckerboardView: View {
    let tileSize: CGFloat = 12

    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                let rows = Int(size.height / tileSize) + 1
                let cols = Int(size.width / tileSize) + 1

                for row in 0..<rows {
                    for col in 0..<cols {
                        let isLight = (row + col) % 2 == 0
                        let rect = CGRect(
                            x: CGFloat(col) * tileSize,
                            y: CGFloat(row) * tileSize,
                            width: tileSize,
                            height: tileSize
                        )
                        context.fill(
                            Path(rect),
                            with: .color(isLight ? Color(white: 0.92) : Color(white: 0.85))
                        )
                    }
                }
            }
        }
    }
}

// MARK: - Preview
#Preview {
    StudioPhotoView()
}
