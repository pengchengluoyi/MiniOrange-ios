import SwiftUI

@main
struct MiniOrangeIApp: App {
    @Environment(\.scenePhase) var scenePhase
    @StateObject var serverManager = ServerManager.shared // 监听 ServerManager
    
    var body: some Scene {
        WindowGroup {
            // 如果有已经连接或选中的服务器，进入主界面
            if serverManager.currentServer != nil {
                MainTabView()
            } else {
                // 否则进入连接/扫码页
                ConnectionView {
                    // 回调：当 ConnectionView 完成配置并连接后
                    // 视图会自动刷新，因为 serverManager.currentServer 变了
                }
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                // 回到前台，如果之前有连接，尝试重连
                if let current = serverManager.currentServer {
                    WebSocketManager.shared.setup(url: current.u)
                }
            }
        }
    }
}

struct MainTabView: View {
    var body: some View {
        TabView {
            DashboardView().tabItem { Label("Dashboard", systemImage: "square.grid.2x2") }
            DeviceListView().tabItem { Label("Devices", systemImage: "desktopcomputer") }
            SettingsView().tabItem { Label("Settings", systemImage: "gear") }
        }
    }
}
