import SwiftUI
import UIKit

// MARK: - Orientation Manager
// Singleton that controls which orientations are allowed at runtime.
// ShootingView sets .landscapeRight for Face 4 mode, portrait for everything else.

class OrientationManager {
    static let shared = OrientationManager()

    var allowedOrientations: UIInterfaceOrientationMask = .portrait

    /// Lock to landscape right and request rotation
    func forceLandscape() {
        allowedOrientations = .landscape
        rotateDevice(to: .landscapeRight)
    }

    /// Lock to portrait and request rotation
    func forcePortrait() {
        allowedOrientations = .portrait
        rotateDevice(to: .portrait)
    }

    /// Unlock all orientations (default app behavior)
    func unlockAll() {
        allowedOrientations = [.portrait, .landscapeLeft, .landscapeRight]
    }

    private func rotateDevice(to orientation: UIInterfaceOrientation) {
        DispatchQueue.main.async {
            guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }

            // Step 1: Tell the root view controller to re-query supported orientations
            if let rootVC = windowScene.windows.first?.rootViewController {
                rootVC.setNeedsUpdateOfSupportedInterfaceOrientations()
            }

            // Step 2: Request the actual geometry change
            let mask: UIInterfaceOrientationMask
            switch orientation {
            case .landscapeRight: mask = .landscapeRight
            case .landscapeLeft:  mask = .landscapeLeft
            default:              mask = .portrait
            }

            let prefs = UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: mask)
            windowScene.requestGeometryUpdate(prefs) { _ in }
        }
    }
}

// MARK: - AppDelegate
// Needed to control supported orientations at runtime via OrientationManager.

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        return OrientationManager.shared.allowedOrientations
    }
}

// MARK: - SmartPneuApp
// This is the entry point of the app — the equivalent of main() in other languages.
// It defines the app's main window and the tab navigation.

@main
struct SmartPneuApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            MainTabView()
        }
    }
}

// MARK: - MainTabView
// Three-tab navigation: Studio Photo, Scanner, and History

struct MainTabView: View {
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            // Tab 1: Studio Photo (main feature)
            StudioPhotoView()
                .tabItem {
                    Image(systemName: "camera.aperture")
                    Text("Studio")
                }
                .tag(0)

            // Tab 2: OCR Scanner
            TireScannerView()
                .tabItem {
                    Image(systemName: "camera.viewfinder")
                    Text("Scanner")
                }
                .tag(1)

            // Tab 3: Scan History
            ScanHistoryView()
                .tabItem {
                    Image(systemName: "clock.arrow.circlepath")
                    Text("Historique")
                }
                .tag(2)
        }
        .tint(.orange) // SmartPneu accent color
    }
}
