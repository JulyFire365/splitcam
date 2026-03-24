import SwiftUI

@main
struct SplitCamApp: App {
    @StateObject private var coordinator = AppCoordinator()

    var body: some Scene {
        WindowGroup {
            NavigationStack(path: $coordinator.path) {
                CameraView(mode: .dualCamera)
                    .navigationDestination(for: AppRoute.self) { route in
                        coordinator.view(for: route)
                    }
            }
            .environmentObject(coordinator)
        }
    }
}
