import SwiftUI

enum EzvpnScene {
    static let mainWindowID = "main"
}

@main
struct EzvpnApp: App {
    @StateObject private var manager = TunnelsManager()

    var body: some Scene {
        #if os(macOS)
        Window("ezvpn", id: EzvpnScene.mainWindowID) {
            TunnelListView()
                .environmentObject(manager)
        }
        .defaultSize(width: 480, height: 600)

        MenuBarExtra("ezvpn", systemImage: "network") {
            MenuBarView()
                .environmentObject(manager)
        }
        .menuBarExtraStyle(.menu)
        #else
        WindowGroup {
            TunnelListView()
                .environmentObject(manager)
        }
        #endif
    }
}
