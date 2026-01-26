import SwiftUI

struct GlobalOfflineModifier: ViewModifier {
    @ObservedObject var wsManager = WebSocketManager.shared
    
    func body(content: Content) -> some View {
        ZStack(alignment: .bottom) {
            content

            if wsManager.isDeviceOfflineFromCluster {
                VStack(spacing: 12) {
                    HStack(spacing: 16) {
                        Image(systemName: "exclamationmark.shield.fill")
                            .font(.system(size: 32))
                            .foregroundColor(.white)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("设备已下线")
                                .font(.headline)
                                .foregroundColor(.white)
                            Text("当前设备已被移出集群或服务端已注销，请重新扫码绑定。")
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.9))
                        }
                        Spacer()
                    }
                    .padding()
                    .background(Color.red.opacity(0.95))
                    .cornerRadius(16)
                    .shadow(color: Color.black.opacity(0.2), radius: 10, x: 0, y: 5)
                }
                .padding(.horizontal)
                .padding(.bottom, 20)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(999)
            }
        }
        .animation(.spring(), value: wsManager.isDeviceOfflineFromCluster)
    }
}

extension View {
    func showOfflineBanner() -> some View {
        self.modifier(GlobalOfflineModifier())
    }
}