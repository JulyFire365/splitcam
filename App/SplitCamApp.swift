import SwiftUI

@main
struct SplitCamApp: App {
    @StateObject private var coordinator = AppCoordinator()
    @StateObject private var reviewPromptManager = ReviewPromptManager.shared

    var body: some Scene {
        WindowGroup {
            #if DEBUG && targetEnvironment(simulator)
            if ScreenshotSupport.screen != nil {
                ScreenshotPreviewRoot().environmentObject(coordinator)
            } else {
                mainContent
            }
            #else
            mainContent
            #endif
        }
    }

    private var mainContent: some View {
        ZStack {
            NavigationStack(path: $coordinator.path) {
                CameraView(mode: .dualCamera)
                    .navigationDestination(for: AppRoute.self) { route in
                        coordinator.view(for: route)
                    }
            }
            if #available(iOS 18.0, *) {
                ReviewPromptHost(
                    manager: reviewPromptManager,
                    isAtRoot: coordinator.path.isEmpty,
                    navigationRevision: coordinator.navigationRevision
                )
            } else {
                LegacyReviewPromptHost(
                    manager: reviewPromptManager,
                    isAtRoot: coordinator.path.isEmpty,
                    navigationRevision: coordinator.navigationRevision
                )
            }
        }
        .environmentObject(coordinator)
    }
}
