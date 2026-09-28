import QwoviKit
import SwiftUI

@main
struct QwoviApp: App {
    @StateObject private var model = PhoneModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            PagerView()
                .environmentObject(model)
                .environmentObject(model.pointer)
                .statusBarHidden()
                .persistentSystemOverlays(.hidden)
                .task {
                    UIApplication.shared.isIdleTimerDisabled = true
                    model.start()
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { model.sceneBecameActive() }
                }
        }
    }
}
