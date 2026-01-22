import SwiftUI
import SwiftData

@main
struct MiniOrangeIApp: App {
    // 1. 引入环境遍历监听 App 状态（活跃/后台/非活跃）
    @Environment(\.scenePhase) var scenePhase

    // 2. 移除 @StateObject 包装，直接使用单例，或者仅作为普通属性引用
    // @StateObject var wsManager = WebSocketManager.shared // 不推荐这样包装单例

    @AppStorage("connectionConfig") private var storedConfigData: Data = Data()

    var body: some Scene {
        WindowGroup {
            // 只要本地有配置数据，就尝试显示主界面
            if !storedConfigData.isEmpty {
                MainTabView()
                    .onAppear {
                        // 冷启动时触发
                        print("📱 [App] App 启动，尝试连接...")
                        checkAutoConnect()
                    }
            } else {
                ConnectionView {
                    // 连接成功回调
                }
            }
        }
        // 3. 监听生命周期变化：处理从后台切回前台的情况
        .onChange(of: scenePhase) {_, newPhase in
            if newPhase == .active {
                print("📱 [App] App 回到前台，检查连接状态...")
                // 只有配置存在时才尝试重连
                if !storedConfigData.isEmpty {
                    checkAutoConnect()
                }
            }
        }
    }

    private func checkAutoConnect() {
        let manager = WebSocketManager.shared

        // 只有未连接且未在连接中时才尝试连接
        guard !manager.isConnected, !manager.isConnecting else {
            print("⚠️ [App] 已连接或正在连接中，跳过重连请求")
            return
        }

        // 4. 去掉 try?，捕获错误以便调试，确认是否是数据损坏导致无法解析
        do {
            let config = try JSONDecoder().decode(ConnectionConfig.self, from: storedConfigData)
            print("✅ [App] 读取配置成功，开始连接 Server: \(config.u)")
            manager.setup(url: config.u, token: config.t)
        } catch {
            print("❌ [App] 配置解析失败，可能数据已损坏。错误: \(error)")
            // 可选：如果解析失败，可能需要清除错误数据让用户重新扫码
            // storedConfigData = Data()
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
